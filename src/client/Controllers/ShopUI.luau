--!strict
-- CRYPTLINGS: NIGHT SHIFT — ShopUI (Stage 6, module shop-ui).
-- The launch-week storefront (SOP §4.1–4.3) behind the §8.1 compliance gates:
--   * Entry points: hub shop kiosk tap (client-local ProximityPrompt on any
--     part tagged "ShopKiosk") + a persistent HUD shop chip (under the locker
--     chip, same left-edge rail).
--   * Renders Shop.GetCatalog ONLY — the server is the compliance filter
--     (ComplianceService + Economy/Flags). This controller NEVER builds its
--     card list from local ProductCatalog reads; a fresh catalog is fetched on
--     every open so owned/restricted/flag changes land immediately.
--   * Tabs: SUPPLIES (consumables) / CASES (bundles) / PASSES. With
--     randomRestricted=true the CASES tab does not exist at all, every
--     isRandom entry is dropped client-side as defense in depth, and no copy
--     references box randomness (§8.1: restricted players see only
--     deterministic SKUs).
--   * Every isRandom card renders its FULL odds table INLINE on the card,
--     visible BEFORE any purchase prompt can be raised (§8.1 pre-purchase
--     disclosure), in rarity colors, captioned "Odds identical to the hub
--     board." Odds come from the server catalog payload (entry.odds — fed by
--     the same RarityTable of record as GetOddsTable and the hub board).
--   * Bundle cards: case count + escalating "+X% BONUS VALUE" ribbon (§4.3) +
--     the sealed-cases note that cross-sells VIP Locker ("cases are sealed —
--     opened from your locker; VIP Locker opens 6/day"). Prices are rendered
--     verbatim from server data (charm ladder 49/39/75/149/240..., §4.2).
--   * Pass cards show an OWNED badge; the VIP Locker card explains "open
--     6/day".
--   * HOUSING tab (LOBBY_SOP §5.4/§8 — WP4.3): renders only the housing rows
--     the server already filtered through ProductCatalog's
--     requiresHousingTier gate (the client NEVER re-derives offer validity);
--     one highlighted "next step" CTA card on top whose copy matches the lot
--     sign verbatim (LobbyConfig.HOUSING_CTA_FALLBACK + livePriceRobux), the
--     mansion card anchored largest with "BEST VALUE: 60 pet slots", live
--     GetProductInfo prices (entry.livePriceRobux) over the PriceLadder
--     fallback, and reached tiers marked "OWNED ✓". Buy on a housing card
--     fires the ARGUMENT-LESS Shop.PromptHousing remote — the server computes
--     the SKU from profile.housing.tier (§5.1); housing never reaches the
--     client-side PromptProductPurchase path.
--   * Counter QOL (SOP §8): the kiosk ProximityPrompt is disabled while the
--     sheet is open, and a session opened AT the counter auto-closes once the
--     player walks > 15 studs from the kiosk.
--   * Purchase: MarketplaceService PromptProductPurchase /
--     PromptGamePassPurchase by assetId from the catalog payload (server fills
--     assetIds from the Creator Dashboard; 0 = not wired yet -> polite toast,
--     no prompt). ShopGrant -> success toast with the server's summary.
--   * Fires FunnelClient {event="ui_open_shop"} every open (§H whitelist —
--     the server tracks shop_open).
--
-- Mobile-first (§3.2/§G): bottom sheet, one-thumb reach, every tap target
-- >= 44px, portrait-safe width cap.
--
-- Public API (Controllers.Get("ShopUI")):
--   ShopUI.Open(tab?) / ShopUI.Close() / ShopUI.Toggle() / ShopUI.IsOpen()
--       Open("Housing") deep-links to the housing tab (SOP §8 — lot sign /
--       ghost preview mirrors); a non-tab string is treated as a sku and
--       forwarded to OpenTo, so both addressing styles work everywhere.
--   ShopUI.OpenTo(sku)  -- deep link: opens the shop on the tab containing
--       sku and highlights that card (LockerUI's 49 R$ EXTRA_OPENING link).

local CollectionService = game:GetService("CollectionService")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConstants = require(Shared:WaitForChild("Config"):WaitForChild("GameConstants"))
local LobbyConfig = require(Shared:WaitForChild("Config"):WaitForChild("LobbyConfig"))
local RarityTable = require(Shared:WaitForChild("Config"):WaitForChild("RarityTable"))
local HouseTransitions = require(Shared:WaitForChild("Logic"):WaitForChild("HouseTransitions"))
local Remotes = require(Shared:WaitForChild("Net"):WaitForChild("Remotes"))
local Types = require(Shared:WaitForChild("Types"))

local LocalPlayer = Players.LocalPlayer

--------------------------------------------------------------------------------
-- Tuning (cosmetic, this module's domain)
--------------------------------------------------------------------------------

-- Hub kiosk discovery: HubService tags the kiosk part; until it exists the HUD
-- chip is the storefront door.
local TAG_SHOP_KIOSK = "ShopKiosk"
local PROMPT_ACTION_TEXT = "Open Shop"
local PROMPT_DISTANCE = LobbyConfig.SHOP_PROMPT_DISTANCE_STUDS -- 10 (SOP §8)
local AUTOCLOSE_DISTANCE = LobbyConfig.SHOP_AUTOCLOSE_DISTANCE_STUDS -- 15 (SOP §8)
local AUTOCLOSE_POLL_SECONDS = 0.25

-- Touch sizing: every interactive target >= the §G mobile gate.
local MIN_TOUCH_PX = GameConstants.MOBILE_MIN_TOUCH_TARGET_PX -- 44
local CLOSE_PX = math.max(MIN_TOUCH_PX, 48)
local TAB_HEIGHT_PX = math.max(MIN_TOUCH_PX, 46)
local BUY_WIDTH_PX = 108
local BUY_HEIGHT_PX = math.max(MIN_TOUCH_PX, 48)
local CHIP_WIDTH_PX = 84
local CHIP_HEIGHT_PX = math.max(MIN_TOUCH_PX, 68)

-- Bottom sheet (one-thumb, §3.2) — same silhouette as LockerUI.
local SHEET_HEIGHT_SCALE = 0.74
local SHEET_MAX_WIDTH_PX = 720
local SHEET_SLIDE_SECONDS = 0.18

-- Card metrics (single-column list; heights computed per card content).
local CARD_PAD_PX = 12
local CARD_GAP_PX = 8
local TITLE_HEIGHT_PX = 22
local DESC_HEIGHT_PX = 30
local RIBBON_HEIGHT_PX = 22
local NOTE_HEIGHT_PX = 28
local ODDS_HEADER_HEIGHT_PX = 16
local ODDS_ROW_HEIGHT_PX = 22
local ODDS_CAPTION_HEIGHT_PX = 16
local NEXT_STEP_CAPTION_HEIGHT_PX = 14
local NEXT_STEP_LABEL_HEIGHT_PX = 22
local MANSION_CARD_MIN_HEIGHT_PX = 140 -- "anchored largest" (LOBBY_SOP §5.4)

local CATALOG_FETCH_TIMEOUT_SECONDS = 6
local TOAST_SECONDS = 3.2
local HIGHLIGHT_SECONDS = 1.6

-- Palette (matches LockerUI/OddsUI greybox chrome).
local COLOR_PANEL = Color3.fromRGB(18, 20, 24)
local COLOR_PANEL_RAISED = Color3.fromRGB(30, 33, 39)
local COLOR_CARD = Color3.fromRGB(26, 29, 34)
local COLOR_TEXT = Color3.fromRGB(235, 238, 240)
local COLOR_TEXT_DIM = Color3.fromRGB(160, 166, 172)
local COLOR_ACCENT = Color3.fromRGB(80, 220, 120)
local COLOR_GOLD = Color3.fromRGB(235, 190, 52)
local COLOR_TAB_SELECTED = Color3.fromRGB(70, 120, 180)
local COLOR_SCRIM = Color3.fromRGB(8, 9, 12)
local COLOR_PIP_EMPTY = Color3.fromRGB(60, 64, 70)
local COLOR_FALLBACK = Color3.fromRGB(178, 178, 178)

-- DisplayOrder 17: above the locker sheet (16), below the unboxing theater
-- (20) / OddsUI (24) / broadcasts (40). Toast rides higher so it clears the
-- theater after a grant.
local DISPLAY_ORDER = 17
local TOAST_DISPLAY_ORDER = 30

local TAB_ORDER = { "Supplies", "Cases", "Passes", "Housing" }
local TAB_LABELS: { [string]: string } = {
	Supplies = "SUPPLIES",
	Cases = "CASES",
	Passes = "PASSES",
	Housing = "HOUSING",
}

-- Friendly one-liners per SKU (copy only — list/price/odds all come from the
-- server payload). Numbers quoted from GameConstants, never magic.
local DESCRIPTIONS: { [string]: string } = {
	STARTER_PACK = "1 Foreman's Key + 2 extra openings + the exclusive Misprint Trophy. One per account.",
	EXTRA_OPENING = "Open one more case from your locker tonight.",
	SCENT_SPRAY = "Carrying cases doesn't slow you down for one full run.",
	REVIVE_BEACON = "One-use instant revive for a downed teammate.",
	FOREMANS_KEY = "Unlocks 1 bonus vault case — deep-vault odds below.",
	PASS_2X_PAY = "Double shift pay on every extraction. Forever.",
	PASS_GOLDEN_SET = "Golden Flashlight + Foreman cosmetic set.",
	HOUSING_HOUSE = "A house on your lot — display 12 Pets inside instead of 8 podiums.",
	HOUSING_TWO_STORY = "A 2-story house on your lot — 24 displays, 12 per story, walkable stairs.",
	HOUSING_TWO_STORY_UP = "Add a second story to your house — 24 displays total. House-owner price.",
	HOUSING_MANSION = "The full Mansion: 5 floors, 12 displays each (60 total), grand staircase.",
	HOUSING_MANSION_UP_HOUSE = "Trade the house up to the 5-floor Mansion — 60 displays. House-owner price.",
	HOUSING_MANSION_UP_TWO_STORY = "Trade up to the 5-floor Mansion — 60 displays. 2-Story-owner price.",
}

-- The three possible "next step" SKUs, keyed back to the tier whose lot sign
-- they caption. Built from HouseTransitions.NextCta — the SAME single source
-- the server's GetHousingCtaText/PromptNextHousing read — so the shop's CTA
-- card and the lot sign can never drift (LOBBY_SOP §5.4).
local HOUSING_CTA_TIER_BY_SKU: { [string]: number } = {}
for tier = 0, GameConstants.HOUSING_MAX_TIER - 1 do
	local ctaSku = HouseTransitions.NextCta(tier)
	if ctaSku ~= nil then
		HOUSING_CTA_TIER_BY_SKU[ctaSku] = tier
	end
end

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local ShopUI = {}

type Catalog = { items: { Types.CatalogEntry }, randomRestricted: boolean }

local catalog: Catalog? = nil
local isOpen = false
local activeTab = "Supplies"
local shiftStateName = "Intermission"
local lockedMidRun = false -- Active shift AND this player clocked in (§4.1)
local fetchInFlight = false
local pendingHighlightSku: string? = nil

local registryRef: any = nil -- Controllers registry (CursorUnlock lookup)

-- R4-2: free the first-person cursor while the sheet is open. Safe registry
-- lookup, nil-guarded no-op until CursorUnlock registers; token = module name.
-- Every path that hides the sheet funnels through ShopUI.Close, which releases.
local function setCursorUnlocked(unlocked: boolean)
	if registryRef == nil or type(registryRef.Get) ~= "function" then
		return
	end
	local cursorUnlock = registryRef.Get("CursorUnlock")
	if cursorUnlock == nil then
		return
	end
	if unlocked then
		cursorUnlock.acquire("ShopUI")
	else
		cursorUnlock.release("ShopUI")
	end
end

local ui: any = nil -- bottom sheet refs (lazy)
local chip: any = nil -- HUD chip refs (built in Start)
local toastUi: any = nil -- toast refs (lazy)
local toastToken = 0
local prompt: ProximityPrompt? = nil

--------------------------------------------------------------------------------
-- Small helpers
--------------------------------------------------------------------------------

local function makeLabel(name: string, textSize: number, bold: boolean): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = name
	label.BackgroundTransparency = 1
	label.Font = if bold then Enum.Font.GothamBold else Enum.Font.Gotham
	label.TextSize = textSize
	label.TextColor3 = COLOR_TEXT
	return label
end

local function makeRound(parent: GuiObject, radius: number)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius)
	corner.Parent = parent
end

local function rarityColor(rarity: string): Color3
	local color = (RarityTable.RARITY_COLORS :: any)[rarity]
	if typeof(color) == "Color3" then
		return color
	end
	return COLOR_FALLBACK
end

-- Exact percentage text: 65 -> "65%", 0.9 -> "0.9%", 0.001 -> "0.001%"
-- (weights are integers /1,000,000 = RarityTable.WEIGHT_TOTAL, so four
-- decimals always suffice; trailing zeros trimmed). Same formatting as OddsUI
-- and the hub board so the disclosure reads identically everywhere (§8.1).
local function formatPct(pct: number): string
	if pct == math.floor(pct) then
		return string.format("%d%%", pct)
	end
	local text = string.format("%.4f", pct)
	text = string.gsub(text, "0+$", "")
	text = string.gsub(text, "%.$", "")
	return text .. "%"
end

local function fireFunnel(event: string)
	task.spawn(function()
		local ok, remote = pcall(Remotes.GetEvent, "FunnelClient")
		if ok then
			(remote :: RemoteEvent):FireServer({ event = event })
		end
	end)
end

local function isOddsArray(value: any): boolean
	if type(value) ~= "table" or #value == 0 then
		return false
	end
	for _, row in value :: { any } do
		if type(row) ~= "table" or type(row.rarity) ~= "string" or type(row.pct) ~= "number" then
			return false
		end
	end
	return true
end

local function isCatalogEntryShaped(entry: any): boolean
	return type(entry) == "table"
		and type(entry.sku) == "string"
		and type(entry.displayName) == "string"
		and type(entry.priceRobux) == "number"
		and (entry.kind == "DevProduct" or entry.kind == "GamePass")
		and type(entry.isRandom) == "boolean"
end

local function isCatalogShaped(payload: any): boolean
	if type(payload) ~= "table" or type(payload.items) ~= "table" or type(payload.randomRestricted) ~= "boolean" then
		return false
	end
	for _, entry in payload.items :: { any } do
		if not isCatalogEntryShaped(entry) then
			return false
		end
	end
	return true
end

local function isBundleSku(sku: string): boolean
	return string.sub(sku, 1, 12) == "CASE_BUNDLE_"
end

local function isHousingSku(sku: string): boolean
	return string.sub(sku, 1, 8) == "HOUSING_"
end

-- Every SKU that lands the player at mansion tier (HOUSING_MANSION and both
-- _UP_ paths) — the BEST VALUE anchor whatever tier is shopping (SOP §5.4).
local function isMansionSku(sku: string): boolean
	return string.sub(sku, 1, 15) == "HOUSING_MANSION"
end

-- The single state-gated next step (SOP §5.4): at most ONE non-owned entry in
-- any server-filtered catalog can match (the server only sends rows priced
-- for the player's exact tier).
local function isHousingCtaEntry(entry: Types.CatalogEntry): boolean
	return entry.owned ~= true and HOUSING_CTA_TIER_BY_SKU[entry.sku] ~= nil
end

-- Displayed price: GetProductInfo-live when the server resolved one
-- (entry.livePriceRobux, SOP §5.4 "never hardcode price labels"), PriceLadder
-- row otherwise. Non-housing rows keep their server price verbatim.
local function displayPriceRobux(entry: Types.CatalogEntry): number
	if isHousingSku(entry.sku) and type(entry.livePriceRobux) == "number" then
		return entry.livePriceRobux :: number
	end
	return entry.priceRobux
end

-- The CTA card's headline, IDENTICAL to the lot sign: the SOP §5.4 verbatim
-- fallback copy with the live price substituted when known — the exact
-- transform MonetizationService.GetHousingCtaText applies server-side.
local function housingCtaLabel(entry: Types.CatalogEntry): string?
	local tier = HOUSING_CTA_TIER_BY_SKU[entry.sku]
	if tier == nil then
		return nil
	end
	local label: string? = LobbyConfig.HOUSING_CTA_FALLBACK[tier]
	if label == nil then
		return nil
	end
	local livePrice = entry.livePriceRobux
	if type(livePrice) == "number" then
		label = string.gsub(label :: string, "%d+ R%$", `{livePrice} R$`, 1)
	end
	return label
end

-- Housing tab order (SOP §5.4): the next-step CTA on top, the mansion BEST
-- VALUE anchor under it, remaining offers, then already-reached tiers last.
local function housingOrderRank(entry: Types.CatalogEntry): number
	if entry.owned == true then
		return 4
	end
	if isHousingCtaEntry(entry) then
		return 1
	end
	if isMansionSku(entry.sku) then
		return 2
	end
	return 3
end

local function tabForEntry(entry: Types.CatalogEntry): string
	if isHousingSku(entry.sku) then
		return "Housing"
	end
	if entry.kind == "GamePass" then
		return "Passes"
	end
	if isBundleSku(entry.sku) then
		return "Cases"
	end
	return "Supplies"
end

local function descriptionFor(entry: Types.CatalogEntry): string
	local known = DESCRIPTIONS[entry.sku]
	if known ~= nil then
		return known
	end
	if entry.sku == "PASS_CARRY" then
		return `Carry {GameConstants.BASE_CARRY_SLOTS + GameConstants.PASS_CARRY_BONUS} cases per run instead of {GameConstants.BASE_CARRY_SLOTS}.`
	end
	if entry.sku == "PASS_VIP_LOCKER" then
		return `Open {GameConstants.VIP_OPENS_PER_DAY} cases a day instead of {GameConstants.FREE_OPENS_PER_DAY}.`
	end
	if isBundleSku(entry.sku) then
		local count = string.match(entry.displayName, "%d+")
		if count ~= nil then
			return `{count} Tier 2 sealed cases, straight to your locker.`
		end
		return "Tier 2 sealed cases, straight to your locker."
	end
	return ""
end

--------------------------------------------------------------------------------
-- Catalog fetch (guarded: an unbound/slow remote can never hang the UI)
--------------------------------------------------------------------------------

local renderActiveTab: () -> () -- forward-declared
local restyleTabs: () -> () -- forward-declared

local function fetchCatalog(timeoutSeconds: number): Catalog?
	local response: any = nil
	local done = false
	task.spawn(function()
		local ok, result = pcall(function()
			return Remotes.GetFunction("Shop.GetCatalog"):InvokeServer()
		end)
		if ok then
			response = result
		end
		done = true
	end)
	local deadline = os.clock() + timeoutSeconds
	while not done and os.clock() < deadline do
		task.wait(0.05)
	end
	if isCatalogShaped(response) then
		return response :: Catalog
	end
	return nil
end

local function applyCatalog(fresh: Catalog)
	catalog = fresh
	-- §8.1: with randomness restricted the CASES tab must not exist; if the
	-- player was parked on it, fall back to SUPPLIES.
	if fresh.randomRestricted and activeTab == "Cases" then
		activeTab = "Supplies"
	end
	if ui ~= nil and isOpen then
		restyleTabs()
		renderActiveTab()
	end
end

local function requestCatalogRefresh()
	if fetchInFlight then
		return
	end
	fetchInFlight = true
	task.spawn(function()
		local fresh = fetchCatalog(CATALOG_FETCH_TIMEOUT_SECONDS)
		fetchInFlight = false
		if fresh ~= nil then
			applyCatalog(fresh)
		elseif ui ~= nil and isOpen and catalog == nil then
			ui.emptyLabel.Text = "The shop isn't answering — try again in a moment."
			ui.emptyLabel.Visible = true
		end
	end)
end

--------------------------------------------------------------------------------
-- Toast (own ScreenGui so grants land visibly even over the theater)
--------------------------------------------------------------------------------

local function showToast(text: string)
	if toastUi == nil then
		local gui = Instance.new("ScreenGui")
		gui.Name = "ShopToast"
		gui.ResetOnSpawn = false
		gui.ScreenInsets = Enum.ScreenInsets.DeviceSafeInsets
		gui.DisplayOrder = TOAST_DISPLAY_ORDER

		local frame = Instance.new("Frame")
		frame.Name = "Toast"
		frame.AnchorPoint = Vector2.new(0.5, 1)
		frame.Position = UDim2.new(0.5, 0, 1, -150)
		frame.Size = UDim2.new(1, -48, 0, 54)
		frame.BackgroundColor3 = COLOR_PANEL
		frame.BackgroundTransparency = 0.08
		frame.BorderSizePixel = 0
		frame.Visible = false
		frame.Parent = gui
		makeRound(frame, 14)
		local cap = Instance.new("UISizeConstraint")
		cap.MaxSize = Vector2.new(420, math.huge)
		cap.Parent = frame
		local stroke = Instance.new("UIStroke")
		stroke.Color = COLOR_ACCENT
		stroke.Thickness = 1.5
		stroke.Transparency = 0.35
		stroke.Parent = frame

		local label = makeLabel("Text", 14, true)
		label.Position = UDim2.fromOffset(14, 0)
		label.Size = UDim2.new(1, -28, 1, 0)
		label.TextWrapped = true
		label.Parent = frame

		toastUi = { gui = gui, frame = frame, label = label }
		gui.Parent = LocalPlayer:WaitForChild("PlayerGui")
	end

	toastToken += 1
	local token = toastToken
	toastUi.label.Text = text
	toastUi.frame.Visible = true
	task.delay(TOAST_SECONDS, function()
		if toastToken == token and toastUi ~= nil then
			toastUi.frame.Visible = false
		end
	end)
end

--------------------------------------------------------------------------------
-- Purchase flow — disclosure is structural: prompts can only be raised from a
-- card whose odds table (when isRandom) is already rendered on that card.
--------------------------------------------------------------------------------

-- The ONLY housing purchase path (LOBBY_SOP §5.1): the remote takes NO
-- arguments — the server reads profile.housing.tier and prompts only the
-- HouseTransitions.NextCta SKU. Tapping ANY housing card funnels into that
-- single state-gated next step (the card list is the menu; the server is the
-- cashier) — a client-chosen housing SKU never crosses the wire.
local function promptHousingPurchase(entry: Types.CatalogEntry)
	if entry.owned == true then
		return -- tier already reached: max() grant = charge-for-nothing (§4.3)
	end
	task.spawn(function()
		local ok, result = pcall(function()
			return Remotes.GetFunction("Shop.PromptHousing"):InvokeServer()
		end)
		if not ok or type(result) ~= "table" then
			showToast("The housing counter isn't answering — try again in a moment.")
			return
		end
		if result.ok == true then
			return -- native purchase modal owns the flow from here
		end
		local err = if type(result.err) == "string" then result.err :: string else nil
		if err == "AT_MAX" then
			showToast("Your lot is fully upgraded — the Mansion is the top tier.")
		elseif err == "NOT_LOADED" then
			showToast("Your lot is still loading — try again in a moment.")
		elseif err == "NOT_WIRED" then
			-- Mirrors promptPurchase's dead-assetId seam, but with the SERVER-
			-- selected sku echoed in the response — SKU selection never moves
			-- client-side, even in the Studio simulator.
			if RunService:IsStudio() and type(result.sku) == "string" then
				local okBuy, buyResult = pcall(function()
					return Remotes.GetFunction("Shop.DevBuy"):InvokeServer(result.sku)
				end)
				if okBuy and type(buyResult) == "table" and buyResult.ok == true then
					return -- ShopGrant pushes the success toast; nothing else to do.
				end
				local buyErr = if okBuy and type(buyResult) == "table" then tostring(buyResult.err) else "FAILED"
				showToast(`Studio test purchase failed: {buyErr}`)
			else
				showToast(`{entry.displayName} isn't available right now — check back soon.`)
			end
		end
		-- err == nil: the server's prompt-spam cooldown refused silently
		-- (Security Review Scope §1) — stay quiet client-side too.
	end)
end

local function promptPurchase(entry: Types.CatalogEntry)
	-- owned=true covers passes AND one-per-account dev products (STARTER_PACK):
	-- a second receipt would be consumed server-side with NO grant (§4.3), so
	-- never raise a prompt the player can only lose Robux on.
	if entry.owned == true then
		return
	end
	-- LOBBY_SOP §5.1: housing prompts are server-selected. Housing cards never
	-- reach the client-side PromptProductPurchase path below.
	if isHousingSku(entry.sku) then
		promptHousingPurchase(entry)
		return
	end
	-- §8.1 fail-closed: a random SKU may only be prompted when its odds table
	-- actually rendered on the card. A payload without odds gets no prompt.
	if entry.isRandom and not isOddsArray(entry.odds) then
		showToast("Odds unavailable for this item right now — see the hub odds board.")
		return
	end
	-- assetId is an additive field on the server's catalog payload (0 until the
	-- Creator Dashboard products exist). Never raise a prompt on a dead id —
	-- but in STUDIO, fall back to the Shop.DevBuy playtest simulator so every
	-- shop feature is exercisable before the products are wired.
	local assetId = tonumber((entry :: any).assetId) or 0
	if assetId <= 0 then
		if RunService:IsStudio() then
			task.spawn(function()
				local ok, result = pcall(function()
					return Remotes.GetFunction("Shop.DevBuy"):InvokeServer(entry.sku)
				end)
				if ok and type(result) == "table" and result.ok == true then
					-- ShopGrant pushes the success toast; nothing else to do.
					return
				end
				local err = if ok and type(result) == "table" then tostring(result.err) else "FAILED"
				showToast(`Studio test purchase failed: {err}`)
			end)
		else
			showToast(`{entry.displayName} isn't available right now — check back soon.`)
		end
		return
	end
	local ok, err = pcall(function()
		if entry.kind == "GamePass" then
			MarketplaceService:PromptGamePassPurchase(LocalPlayer, assetId)
		else
			MarketplaceService:PromptProductPurchase(LocalPlayer, assetId)
		end
	end)
	if not ok then
		warn(`[ShopUI] purchase prompt failed for {entry.sku}: {err}`)
		showToast("Couldn't open the purchase prompt — try again.")
	end
end

--------------------------------------------------------------------------------
-- Card construction
--------------------------------------------------------------------------------

-- Inline odds block (§8.1 pre-purchase disclosure). Returns the block height.
-- Renders ONLY the server-supplied odds rows; if the payload omits them the
-- card states that odds are unavailable rather than inventing local numbers.
local function buildOddsBlock(card: Frame, entry: Types.CatalogEntry, y: number): number
	local odds = entry.odds
	if not isOddsArray(odds) then
		local missing = makeLabel("OddsMissing", 12, true)
		missing.Position = UDim2.fromOffset(CARD_PAD_PX, y)
		missing.Size = UDim2.new(1, -CARD_PAD_PX * 2, 0, ODDS_HEADER_HEIGHT_PX + 4)
		missing.TextXAlignment = Enum.TextXAlignment.Left
		missing.TextColor3 = COLOR_TEXT_DIM
		missing.Text = "Odds unavailable — see the hub odds board."
		missing.Parent = card
		return ODDS_HEADER_HEIGHT_PX + 8
	end

	local header = makeLabel("OddsHeader", 11, true)
	header.Position = UDim2.fromOffset(CARD_PAD_PX, y)
	header.Size = UDim2.new(1, -CARD_PAD_PX * 2, 0, ODDS_HEADER_HEIGHT_PX)
	header.TextXAlignment = Enum.TextXAlignment.Left
	header.TextColor3 = COLOR_TEXT_DIM
	header.Text = if entry.sku == "FOREMANS_KEY" or entry.sku == "STARTER_PACK"
		then "VAULT CASE ODDS"
		else "ODDS PER CASE"
	header.Parent = card

	local rowY = y + ODDS_HEADER_HEIGHT_PX + 2
	for index, row in odds :: { Types.OddsRow } do
		local color = rarityColor(row.rarity)

		local dot = Instance.new("Frame")
		dot.Name = `Dot{index}`
		dot.AnchorPoint = Vector2.new(0, 0.5)
		dot.Position = UDim2.fromOffset(CARD_PAD_PX, rowY + ODDS_ROW_HEIGHT_PX // 2)
		dot.Size = UDim2.fromOffset(10, 10)
		dot.BackgroundColor3 = color
		dot.BorderSizePixel = 0
		dot.Parent = card
		local dotCorner = Instance.new("UICorner")
		dotCorner.CornerRadius = UDim.new(1, 0)
		dotCorner.Parent = dot

		local nameLabel = makeLabel(`Rarity{index}`, 13, true)
		nameLabel.Position = UDim2.fromOffset(CARD_PAD_PX + 18, rowY)
		nameLabel.Size = UDim2.new(1, -(CARD_PAD_PX * 2 + 18 + 76), 0, ODDS_ROW_HEIGHT_PX)
		nameLabel.TextXAlignment = Enum.TextXAlignment.Left
		nameLabel.TextColor3 = color
		nameLabel.Text = row.rarity
		nameLabel.Parent = card

		local pctLabel = makeLabel(`Pct{index}`, 13, true)
		pctLabel.AnchorPoint = Vector2.new(1, 0)
		pctLabel.Position = UDim2.new(1, -CARD_PAD_PX, 0, rowY)
		pctLabel.Size = UDim2.fromOffset(72, ODDS_ROW_HEIGHT_PX)
		pctLabel.TextXAlignment = Enum.TextXAlignment.Right
		pctLabel.Text = formatPct(row.pct)
		pctLabel.Parent = card

		rowY += ODDS_ROW_HEIGHT_PX
	end

	-- The §8.1 promise, stated on every random card.
	local caption = makeLabel("OddsCaption", 11, false)
	caption.Position = UDim2.fromOffset(CARD_PAD_PX, rowY + 2)
	caption.Size = UDim2.new(1, -CARD_PAD_PX * 2, 0, ODDS_CAPTION_HEIGHT_PX)
	caption.TextXAlignment = Enum.TextXAlignment.Left
	caption.TextColor3 = COLOR_TEXT_DIM
	caption.Text = "Odds identical to the hub board."
	caption.Parent = card

	return (rowY + 2 + ODDS_CAPTION_HEIGHT_PX + 4) - y
end

local function buildCard(entry: Types.CatalogEntry, order: number): Frame
	local card = Instance.new("Frame")
	card.Name = `Card_{entry.sku}`
	card.BackgroundColor3 = COLOR_CARD
	card.BorderSizePixel = 0
	card.LayoutOrder = order
	makeRound(card, 14)

	local stroke = Instance.new("UIStroke")
	stroke.Name = "CardStroke"
	stroke.Color = COLOR_PIP_EMPTY
	stroke.Thickness = 1
	stroke.Transparency = 0.5
	stroke.Parent = card

	-- Server sets owned for game passes and one-per-account dev products
	-- (STARTER_PACK); both must render OWNED, not a re-buyable price (§4.3).
	local owned = entry.owned == true

	-- Title row + buy button (right rail).
	local title = makeLabel("Title", 16, true)
	title.Position = UDim2.fromOffset(CARD_PAD_PX, 10)
	title.Size = UDim2.new(1, -(CARD_PAD_PX * 3 + BUY_WIDTH_PX), 0, TITLE_HEIGHT_PX)
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextWrapped = true
	title.Text = entry.displayName
	title.Parent = card

	local buy = Instance.new("TextButton")
	buy.Name = "Buy"
	buy.AnchorPoint = Vector2.new(1, 0)
	buy.Position = UDim2.new(1, -CARD_PAD_PX, 0, 10)
	buy.Size = UDim2.fromOffset(BUY_WIDTH_PX, BUY_HEIGHT_PX)
	buy.BorderSizePixel = 0
	buy.Font = Enum.Font.GothamBold
	buy.TextSize = 15
	buy.Parent = card
	makeRound(buy, 12)
	if owned then
		-- OWNED badge: the pass is already theirs — no prompt, no charm price.
		-- Housing rows read "OWNED ✓": the tier was reached (one-way max()
		-- grants), whether bought here or via an upgrade path (LOBBY_SOP §5.4).
		buy.BackgroundColor3 = COLOR_PANEL_RAISED
		buy.TextColor3 = COLOR_ACCENT
		buy.Text = if isHousingSku(entry.sku) then "OWNED ✓" else "OWNED"
		buy.AutoButtonColor = false
	else
		-- Price verbatim from server data (§4.2 charm ladder); housing rows
		-- prefer the GetProductInfo-live price when the server resolved one.
		buy.BackgroundColor3 = COLOR_GOLD
		buy.TextColor3 = COLOR_PANEL
		buy.Text = `{displayPriceRobux(entry)} R$`
		buy.AutoButtonColor = true
	end
	buy.Activated:Connect(function()
		promptPurchase(entry)
	end)

	local y = 10 + TITLE_HEIGHT_PX + 2

	local descText = descriptionFor(entry)
	if descText ~= "" then
		local desc = makeLabel("Desc", 12, false)
		desc.Position = UDim2.fromOffset(CARD_PAD_PX, y)
		desc.Size = UDim2.new(1, -(CARD_PAD_PX * 3 + BUY_WIDTH_PX), 0, DESC_HEIGHT_PX)
		desc.TextXAlignment = Enum.TextXAlignment.Left
		desc.TextYAlignment = Enum.TextYAlignment.Top
		desc.TextWrapped = true
		desc.TextColor3 = COLOR_TEXT_DIM
		desc.Text = descText
		desc.Parent = card
		y += DESC_HEIGHT_PX + 4
	end

	-- Housing surfacing (LOBBY_SOP §5.4 — WP4.3). Presentation only: which
	-- rows exist at all is the server's call (requiresHousingTier filter).
	if isHousingSku(entry.sku) and not owned then
		local ctaText = housingCtaLabel(entry)
		if ctaText ~= nil then
			-- The highlighted "next step" card, copy identical to the lot sign.
			stroke.Color = COLOR_GOLD
			stroke.Thickness = 2
			stroke.Transparency = 0.1

			local nextCaption = makeLabel("NextStepCaption", 11, true)
			nextCaption.Position = UDim2.fromOffset(CARD_PAD_PX, y)
			nextCaption.Size = UDim2.new(1, -(CARD_PAD_PX * 3 + BUY_WIDTH_PX), 0, NEXT_STEP_CAPTION_HEIGHT_PX)
			nextCaption.TextXAlignment = Enum.TextXAlignment.Left
			nextCaption.TextColor3 = COLOR_TEXT_DIM
			nextCaption.Text = "YOUR NEXT STEP"
			nextCaption.Parent = card
			y += NEXT_STEP_CAPTION_HEIGHT_PX

			local ctaLine = makeLabel("NextStepCta", 15, true)
			ctaLine.Position = UDim2.fromOffset(CARD_PAD_PX, y)
			ctaLine.Size = UDim2.new(1, -(CARD_PAD_PX * 3 + BUY_WIDTH_PX), 0, NEXT_STEP_LABEL_HEIGHT_PX)
			ctaLine.TextXAlignment = Enum.TextXAlignment.Left
			ctaLine.TextColor3 = COLOR_GOLD
			ctaLine.Text = ctaText
			ctaLine.Parent = card
			y += NEXT_STEP_LABEL_HEIGHT_PX + 4
		end

		if isMansionSku(entry.sku) then
			-- The anchor (SOP §5.4): sell capacity, not geometry — 60 makes
			-- 499/999 feel cheap.
			local ribbon = makeLabel("BestValue", 13, true)
			ribbon.BackgroundTransparency = 0
			ribbon.BackgroundColor3 = COLOR_GOLD
			ribbon.TextColor3 = COLOR_PANEL
			ribbon.Position = UDim2.fromOffset(CARD_PAD_PX, y)
			ribbon.Size = UDim2.fromOffset(230, RIBBON_HEIGHT_PX + 4)
			ribbon.Text = `BEST VALUE: {GameConstants.HOUSING_MAX_SLOTS} pet slots`
			ribbon.Parent = card
			makeRound(ribbon, 11)
			y += RIBBON_HEIGHT_PX + 8
		end
	end

	if isBundleSku(entry.sku) then
		-- Escalating bonus-value ribbon (§4.3 whale ladder).
		local bonusPct = entry.bonusPct
		if type(bonusPct) == "number" and bonusPct > 0 then
			local ribbon = makeLabel("Ribbon", 12, true)
			ribbon.BackgroundTransparency = 0
			ribbon.BackgroundColor3 = COLOR_GOLD
			ribbon.TextColor3 = COLOR_PANEL
			ribbon.Position = UDim2.fromOffset(CARD_PAD_PX, y)
			ribbon.Size = UDim2.fromOffset(150, RIBBON_HEIGHT_PX)
			ribbon.Text = `+{bonusPct}% BONUS VALUE`
			ribbon.Parent = card
			makeRound(ribbon, 11)
			y += RIBBON_HEIGHT_PX + 4
		end

		-- Sealed-cases note: the locker cap still applies — VIP cross-sell (§4.3).
		local note = makeLabel("SealedNote", 11, false)
		note.Position = UDim2.fromOffset(CARD_PAD_PX, y)
		note.Size = UDim2.new(1, -CARD_PAD_PX * 2, 0, NOTE_HEIGHT_PX)
		note.TextXAlignment = Enum.TextXAlignment.Left
		note.TextYAlignment = Enum.TextYAlignment.Top
		note.TextWrapped = true
		note.TextColor3 = COLOR_TEXT_DIM
		note.Text =
			`Cases are sealed — opened from your locker. VIP Locker opens {GameConstants.VIP_OPENS_PER_DAY}/day.`
		note.Parent = card
		y += NOTE_HEIGHT_PX + 4
	end

	if entry.isRandom then
		-- §8.1: full odds table inline, on the card, BEFORE any prompt.
		y += buildOddsBlock(card, entry, y)
	end

	-- Card height: content vs the buy button's right rail, whichever is taller.
	local height = math.max(y + 8, 10 + BUY_HEIGHT_PX + 10)
	if isMansionSku(entry.sku) and not owned then
		-- "Anchor with the mansion: biggest card" (SOP §5.4) — guaranteed the
		-- tallest housing card on the shelf.
		height = math.max(height, MANSION_CARD_MIN_HEIGHT_PX)
	end
	card.Size = UDim2.new(1, 0, 0, height)
	return card
end

--------------------------------------------------------------------------------
-- Tabs + list rendering
--------------------------------------------------------------------------------

local function visibleTabs(): { string }
	local restricted = catalog ~= nil and (catalog :: Catalog).randomRestricted
	local result = {}
	for _, key in TAB_ORDER do
		if key == "Cases" and restricted then
			continue -- §8.1: no Cases tab at all for restricted players
		end
		table.insert(result, key)
	end
	return result
end

local function highlightCard(card: Frame)
	local stroke = card:FindFirstChild("CardStroke")
	if stroke == nil or not stroke:IsA("UIStroke") then
		return
	end
	stroke.Color = COLOR_GOLD
	stroke.Thickness = 2.5
	stroke.Transparency = 0
	local tween = TweenService:Create(
		stroke,
		TweenInfo.new(HIGHLIGHT_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
		{ Transparency = 0.5, Thickness = 1 }
	)
	tween.Completed:Once(function()
		stroke.Color = COLOR_PIP_EMPTY
	end)
	tween:Play()
end

renderActiveTab = function()
	if ui == nil then
		return
	end
	for _, child in ui.list:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end

	local current = catalog
	if current == nil then
		ui.emptyLabel.Text = "Stocking the shelves..."
		ui.emptyLabel.Visible = true
		return
	end

	local restricted = current.randomRestricted
	local entries: { Types.CatalogEntry } = {}
	for _, entry in current.items do
		-- Defense in depth: even if a random SKU slips into a restricted
		-- payload, it never renders (§8.1 fail-closed).
		if restricted and entry.isRandom then
			continue
		end
		if tabForEntry(entry) ~= activeTab then
			continue
		end
		table.insert(entries, entry)
	end

	-- Housing tab (LOBBY_SOP §5.4): CTA card on top, mansion anchor next,
	-- remaining offers, reached tiers last — stable within ranks so server
	-- (PriceLadder) order is otherwise preserved.
	if activeTab == "Housing" and #entries > 1 then
		local ranked: { { entry: Types.CatalogEntry, index: number } } = {}
		for index, entry in entries do
			table.insert(ranked, { entry = entry, index = index })
		end
		table.sort(ranked, function(a, b)
			local rankA = housingOrderRank(a.entry)
			local rankB = housingOrderRank(b.entry)
			if rankA ~= rankB then
				return rankA < rankB
			end
			return a.index < b.index
		end)
		entries = {}
		for _, item in ranked do
			table.insert(entries, item.entry)
		end
	end

	local count = 0
	local highlightTarget: Frame? = nil
	for _, entry in entries do
		count += 1
		local card = buildCard(entry, count)
		card.Parent = ui.list
		if pendingHighlightSku ~= nil and entry.sku == pendingHighlightSku then
			highlightTarget = card
		end
	end

	ui.emptyLabel.Visible = count == 0
	if count == 0 then
		ui.emptyLabel.Text = "Nothing on this shelf right now."
	end

	if highlightTarget ~= nil then
		pendingHighlightSku = nil
		local card = highlightTarget :: Frame
		task.defer(function()
			if ui ~= nil and card.Parent ~= nil then
				ui.list.CanvasPosition =
					Vector2.new(0, math.max(0, card.AbsolutePosition.Y - ui.list.AbsolutePosition.Y))
				highlightCard(card)
			end
		end)
	end
end

restyleTabs = function()
	if ui == nil then
		return
	end
	local visible: { [string]: boolean } = {}
	for _, key in visibleTabs() do
		visible[key] = true
	end
	for key, tab in ui.tabs :: { [string]: TextButton } do
		tab.Visible = visible[key] == true
		local selected = key == activeTab
		tab.BackgroundColor3 = if selected then COLOR_TAB_SELECTED else COLOR_PANEL_RAISED
		tab.TextColor3 = if selected then COLOR_TEXT else COLOR_TEXT_DIM
	end
end

local function setTab(key: string)
	activeTab = key
	restyleTabs()
	renderActiveTab()
end

--------------------------------------------------------------------------------
-- HUD shop chip (left rail, directly under LockerUI's chip)
--------------------------------------------------------------------------------

local function updateChip()
	if chip ~= nil then
		chip.button.Visible = not lockedMidRun
	end
end

local function buildChip()
	local gui = Instance.new("ScreenGui")
	gui.Name = "ShopChip"
	gui.ResetOnSpawn = false
	gui.ScreenInsets = Enum.ScreenInsets.DeviceSafeInsets
	gui.DisplayOrder = DISPLAY_ORDER - 2 -- under the sheet's scrim and the locker chip

	local button = Instance.new("TextButton")
	button.Name = "Chip"
	button.AnchorPoint = Vector2.new(0, 0.5)
	-- LockerUI's chip sits at (8, 0.56); park directly below it on the same rail.
	button.Position = UDim2.new(0, 8, 0.56, CHIP_HEIGHT_PX + 6)
	button.Size = UDim2.fromOffset(CHIP_WIDTH_PX, CHIP_HEIGHT_PX)
	button.BackgroundColor3 = COLOR_PANEL
	button.BackgroundTransparency = 0.2
	button.BorderSizePixel = 0
	button.Text = ""
	button.AutoButtonColor = true
	button.Parent = gui
	makeRound(button, 12)

	local stroke = Instance.new("UIStroke")
	stroke.Color = COLOR_GOLD
	stroke.Thickness = 1.5
	stroke.Transparency = 0.4
	stroke.Parent = button

	local caption = makeLabel("Caption", 11, true)
	caption.Position = UDim2.fromOffset(0, 6)
	caption.Size = UDim2.new(1, 0, 0, 12)
	caption.TextColor3 = COLOR_TEXT_DIM
	caption.Text = "SHOP"
	caption.Parent = button

	local glyph = makeLabel("Glyph", 24, true)
	glyph.Position = UDim2.fromOffset(0, 18)
	glyph.Size = UDim2.new(1, 0, 0, 26)
	glyph.TextColor3 = COLOR_GOLD
	glyph.Text = "R$"
	glyph.Parent = button

	local sub = makeLabel("Sub", 11, true)
	sub.Position = UDim2.new(0, 0, 1, -18)
	sub.Size = UDim2.new(1, 0, 0, 14)
	sub.TextColor3 = COLOR_TEXT_DIM
	sub.Text = "SUPPLIES"
	sub.Parent = button

	chip = { gui = gui, button = button }
	gui.Parent = LocalPlayer:WaitForChild("PlayerGui")

	button.Activated:Connect(function()
		ShopUI.Toggle()
	end)
	updateChip()
end

--------------------------------------------------------------------------------
-- Bottom sheet construction (lazy: first Open builds it, §G join-time gate)
--------------------------------------------------------------------------------

local function buildTab(parent: GuiObject, key: string, order: number): TextButton
	local tab = Instance.new("TextButton")
	tab.Name = `Tab{key}`
	tab.Size = UDim2.fromOffset(96, TAB_HEIGHT_PX)
	tab.BackgroundColor3 = COLOR_PANEL_RAISED
	tab.BorderSizePixel = 0
	tab.Font = Enum.Font.GothamBold
	tab.TextSize = 14
	tab.TextColor3 = COLOR_TEXT_DIM
	tab.Text = TAB_LABELS[key] or string.upper(key)
	tab.LayoutOrder = order
	tab.Parent = parent
	makeRound(tab, 10)
	return tab
end

local function buildGui()
	local gui = Instance.new("ScreenGui")
	gui.Name = "ShopUI"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = false
	gui.ScreenInsets = Enum.ScreenInsets.DeviceSafeInsets
	gui.DisplayOrder = DISPLAY_ORDER
	-- Instance.new ScreenGuis default to ZIndexBehavior.Global, where the
	-- full-screen scrim (ZIndex 1) z-ties with every default-ZIndex card child
	-- and dims the whole sheet. Sibling makes ZIndex parent-relative, which is
	-- what this layout assumes.
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	local scrim = Instance.new("TextButton")
	scrim.Name = "Scrim"
	scrim.Size = UDim2.fromScale(1, 1)
	scrim.BackgroundColor3 = COLOR_SCRIM
	scrim.BackgroundTransparency = 0.45
	scrim.BorderSizePixel = 0
	scrim.Text = ""
	scrim.AutoButtonColor = false
	scrim.Visible = false
	scrim.ZIndex = 1
	scrim.Parent = gui

	local sheet = Instance.new("Frame")
	sheet.Name = "Sheet"
	sheet.AnchorPoint = Vector2.new(0.5, 1)
	sheet.Position = UDim2.fromScale(0.5, 1)
	sheet.Size = UDim2.fromScale(1, SHEET_HEIGHT_SCALE)
	sheet.BackgroundColor3 = COLOR_PANEL
	sheet.BackgroundTransparency = 0.04
	sheet.BorderSizePixel = 0
	sheet.Visible = false
	sheet.ZIndex = 2
	sheet.Parent = gui
	makeRound(sheet, 18)
	local widthCap = Instance.new("UISizeConstraint")
	widthCap.MaxSize = Vector2.new(SHEET_MAX_WIDTH_PX, math.huge)
	widthCap.Parent = sheet
	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, 14)
	padding.PaddingRight = UDim.new(0, 14)
	padding.PaddingTop = UDim.new(0, 10)
	padding.PaddingBottom = UDim.new(0, 10)
	padding.Parent = sheet

	local notch = Instance.new("Frame")
	notch.Name = "Notch"
	notch.AnchorPoint = Vector2.new(0.5, 0)
	notch.Position = UDim2.fromScale(0.5, 0)
	notch.Size = UDim2.fromOffset(46, 5)
	notch.BackgroundColor3 = COLOR_PIP_EMPTY
	notch.BorderSizePixel = 0
	notch.ZIndex = 3
	notch.Parent = sheet
	makeRound(notch, 3)

	local title = makeLabel("Title", 20, true)
	title.Position = UDim2.fromOffset(2, 12)
	title.Size = UDim2.new(1, -64, 0, 24)
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Text = "SUPPLY COUNTER"
	title.ZIndex = 3
	title.Parent = sheet

	local subtitle = makeLabel("Subtitle", 12, false)
	subtitle.Position = UDim2.fromOffset(2, 38)
	subtitle.Size = UDim2.new(1, -64, 0, 16)
	subtitle.TextXAlignment = Enum.TextXAlignment.Left
	subtitle.TextColor3 = COLOR_TEXT_DIM
	subtitle.Text = "Clock-out spending — the run still earns the box."
	subtitle.ZIndex = 3
	subtitle.Parent = sheet

	local close = Instance.new("TextButton")
	close.Name = "Close"
	close.AnchorPoint = Vector2.new(1, 0)
	close.Position = UDim2.new(1, 0, 0, 6)
	close.Size = UDim2.fromOffset(CLOSE_PX, CLOSE_PX)
	close.BackgroundColor3 = COLOR_PANEL_RAISED
	close.BorderSizePixel = 0
	close.Font = Enum.Font.GothamBold
	close.TextSize = 18
	close.TextColor3 = COLOR_TEXT_DIM
	close.Text = "X"
	close.ZIndex = 3
	close.Parent = sheet
	makeRound(close, 12)

	local tabRow = Instance.new("Frame")
	tabRow.Name = "TabRow"
	tabRow.Position = UDim2.fromOffset(2, 60)
	tabRow.Size = UDim2.new(1, -4, 0, TAB_HEIGHT_PX)
	tabRow.BackgroundTransparency = 1
	tabRow.ZIndex = 3
	tabRow.Parent = sheet
	local tabLayout = Instance.new("UIListLayout")
	tabLayout.FillDirection = Enum.FillDirection.Horizontal
	tabLayout.Padding = UDim.new(0, 8)
	tabLayout.SortOrder = Enum.SortOrder.LayoutOrder
	tabLayout.Parent = tabRow

	local tabs: { [string]: TextButton } = {}
	for order, key in TAB_ORDER do
		tabs[key] = buildTab(tabRow, key, order)
	end

	local listTop = 60 + TAB_HEIGHT_PX + 8
	local list = Instance.new("ScrollingFrame")
	list.Name = "CardList"
	list.Position = UDim2.fromOffset(0, listTop)
	list.Size = UDim2.new(1, 0, 1, -listTop)
	list.BackgroundTransparency = 1
	list.BorderSizePixel = 0
	list.ScrollBarThickness = 6
	list.ScrollBarImageColor3 = COLOR_PIP_EMPTY
	list.ScrollingDirection = Enum.ScrollingDirection.Y
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.CanvasSize = UDim2.new()
	list.ZIndex = 3
	list.Parent = sheet
	local listLayout = Instance.new("UIListLayout")
	listLayout.FillDirection = Enum.FillDirection.Vertical
	listLayout.Padding = UDim.new(0, CARD_GAP_PX)
	listLayout.SortOrder = Enum.SortOrder.LayoutOrder
	listLayout.Parent = list

	local emptyLabel = makeLabel("EmptyState", 15, false)
	emptyLabel.AnchorPoint = Vector2.new(0.5, 0)
	emptyLabel.Position = UDim2.new(0.5, 0, 0, 36)
	emptyLabel.Size = UDim2.new(1, -40, 0, 60)
	emptyLabel.TextColor3 = COLOR_TEXT_DIM
	emptyLabel.TextWrapped = true
	emptyLabel.Visible = false
	emptyLabel.ZIndex = 3
	emptyLabel.Parent = list
	emptyLabel.Text = ""

	ui = {
		gui = gui,
		scrim = scrim,
		sheet = sheet,
		title = title,
		close = close,
		tabs = tabs,
		list = list,
		emptyLabel = emptyLabel,
	}

	gui.Parent = LocalPlayer:WaitForChild("PlayerGui")
end

local function ensureGui()
	if ui ~= nil then
		return
	end
	buildGui()
	ui.close.Activated:Connect(function()
		ShopUI.Close()
	end)
	ui.scrim.Activated:Connect(function()
		ShopUI.Close()
	end)
	for key, tab in ui.tabs :: { [string]: TextButton } do
		tab.Activated:Connect(function()
			setTab(key)
		end)
	end
	restyleTabs()
end

--------------------------------------------------------------------------------
-- Counter QOL (SOP §8): the kiosk prompt is disabled while the sheet is open,
-- and a session opened AT the counter auto-closes on walk-away (> 15 studs).
--------------------------------------------------------------------------------

local function findKiosk(): BasePart?
	for _, instance in CollectionService:GetTagged(TAG_SHOP_KIOSK) do
		if instance:IsA("BasePart") then
			return instance
		end
	end
	return nil
end

local function setPromptEnabled(enabled: boolean)
	if prompt ~= nil then
		(prompt :: ProximityPrompt).Enabled = enabled
	end
end

local function rootPosition(): Vector3?
	local character = LocalPlayer.Character
	if character == nil then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if root ~= nil and root:IsA("BasePart") then
		return root.Position
	end
	return nil
end

-- Token retires stale watchers on Close/re-Open (never two loops at once).
local autoCloseToken = 0

local function startAutoCloseWatch()
	autoCloseToken += 1
	local token = autoCloseToken
	local kiosk = findKiosk()
	local position = rootPosition()
	if kiosk == nil or position == nil then
		return
	end
	if (position - kiosk.Position).Magnitude > AUTOCLOSE_DISTANCE then
		return -- opened away from the counter (HUD chip / deep link): no watcher
	end
	task.spawn(function()
		while isOpen and token == autoCloseToken and kiosk.Parent ~= nil do
			local current = rootPosition()
			if current ~= nil and (current - kiosk.Position).Magnitude > AUTOCLOSE_DISTANCE then
				ShopUI.Close()
				return
			end
			task.wait(AUTOCLOSE_POLL_SECONDS)
		end
	end)
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

function ShopUI.IsOpen(): boolean
	return isOpen
end

-- Open(tab?) — SOP §8 deep links: Open("Housing") lands on the housing tab
-- (the lot sign / ghost preview "Upgrade" mirror). A non-tab string is
-- treated as a sku and forwarded to OpenTo, so Open doubles as its alias.
function ShopUI.Open(tab: string?)
	if type(tab) == "string" and tab ~= "" then
		local matched: string? = nil
		for _, key in TAB_ORDER do
			if string.lower(key) == string.lower(tab) then
				matched = key
				break
			end
		end
		if matched == nil then
			ShopUI.OpenTo(tab) -- sku-style deep link
			return
		end
		-- §8.1: the Cases tab does not exist for restricted players — a deep
		-- link can't conjure it (unknown restriction state = allow; render
		-- still fail-closes).
		local current = catalog
		if matched ~= "Cases" or current == nil or not current.randomRestricted then
			activeTab = matched
		end
	end
	if isOpen then
		-- Already open: a tab deep link just re-tabs in place.
		restyleTabs()
		renderActiveTab()
		return
	end
	if lockedMidRun then
		return -- no shopping mid-run (§4.1: never sell mid-run opens)
	end
	ensureGui()
	isOpen = true
	setCursorUnlocked(true) -- R4-2: cursor free while the sheet is up
	setPromptEnabled(false) -- counter QOL (SOP §8): no prompt under the sheet

	ui.scrim.Visible = true
	ui.sheet.Visible = true
	ui.sheet.Position = UDim2.fromScale(0.5, 1.25)
	TweenService:Create(
		ui.sheet,
		TweenInfo.new(SHEET_SLIDE_SECONDS, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
		{ Position = UDim2.fromScale(0.5, 1) }
	):Play()

	fireFunnel("ui_open_shop") -- server side tracks shop_open (§H)
	restyleTabs()
	renderActiveTab() -- last catalog renders instantly...
	requestCatalogRefresh() -- ...while a fresh one is fetched
	startAutoCloseWatch() -- counter sessions close on walk-away (SOP §8)
end

function ShopUI.Close()
	if not isOpen then
		return
	end
	isOpen = false
	setCursorUnlocked(false) -- R4-2: first person re-locks next frame
	autoCloseToken += 1 -- retire any walk-away watcher
	setPromptEnabled(true) -- the counter prompt is usable again
	if ui ~= nil then
		ui.scrim.Visible = false
		ui.sheet.Visible = false
	end
end

function ShopUI.Toggle()
	if isOpen then
		ShopUI.Close()
	else
		ShopUI.Open()
	end
end

-- Deep link (LockerUI's blocked sheet -> EXTRA_OPENING, Stage 3 contract):
-- opens the shop on the tab containing sku and highlights that card once the
-- catalog has rendered. Unknown/filtered SKUs just open the shop.
function ShopUI.OpenTo(sku: string)
	if type(sku) ~= "string" or sku == "" then
		ShopUI.Open()
		return
	end
	pendingHighlightSku = sku

	-- Pick the tab from the freshest catalog we have; the pending highlight
	-- survives the refresh and re-applies on render.
	local current = catalog
	if current ~= nil then
		for _, entry in current.items do
			if entry.sku == sku then
				local tab = tabForEntry(entry)
				if tab ~= "Cases" or not current.randomRestricted then
					activeTab = tab
				end
				break
			end
		end
	end

	if isOpen then
		restyleTabs()
		renderActiveTab()
		requestCatalogRefresh()
	else
		ShopUI.Open()
	end
end

--------------------------------------------------------------------------------
-- Hub kiosk ProximityPrompt (client-local; tappable on touch)
--------------------------------------------------------------------------------

local function refreshPrompt()
	local kiosk = findKiosk()
	if prompt ~= nil and prompt.Parent == kiosk then
		return
	end
	if prompt ~= nil then
		prompt:Destroy()
		prompt = nil
	end
	if kiosk == nil then
		return
	end
	local newPrompt = Instance.new("ProximityPrompt")
	newPrompt.Name = "ShopPrompt"
	newPrompt.ActionText = PROMPT_ACTION_TEXT
	newPrompt.ObjectText = "Shop"
	newPrompt.HoldDuration = 0 -- single tap on touch
	newPrompt.MaxActivationDistance = PROMPT_DISTANCE
	newPrompt.RequiresLineOfSight = false
	newPrompt.Enabled = not isOpen -- counter QOL: no prompt while the sheet is up
	newPrompt.Parent = kiosk
	newPrompt.Triggered:Connect(function()
		ShopUI.Open()
	end)
	prompt = newPrompt
end

--------------------------------------------------------------------------------
-- Server event handlers
--------------------------------------------------------------------------------

local function onShopGrant(payload: any)
	if type(payload) ~= "table" or type(payload.sku) ~= "string" then
		return
	end
	local summary = if type(payload.summary) == "string" and payload.summary ~= ""
		then payload.summary
		else "Purchase delivered."
	showToast(`PURCHASE COMPLETE — {summary}`)
	-- Owned flags / one-per-account availability may have changed.
	if isOpen then
		requestCatalogRefresh()
	else
		catalog = nil -- stale; next open refetches before trusting it
	end
end

local function onShiftState(payload: any)
	if type(payload) ~= "table" or type(payload.state) ~= "string" then
		return
	end
	shiftStateName = payload.state
	-- Only a clocked-in (not yet extracted) runner loses the storefront; hub
	-- bystanders keep it through shifts they're not part of.
	lockedMidRun = shiftStateName == "Active" and payload.participant == true
	if lockedMidRun then
		ShopUI.Close() -- no storefront mid-run
	end
	updateChip()
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function ShopUI:Init(registry: any)
	registryRef = registry
	CollectionService:GetInstanceAddedSignal(TAG_SHOP_KIOSK):Connect(function()
		task.defer(refreshPrompt)
	end)
	CollectionService:GetInstanceRemovedSignal(TAG_SHOP_KIOSK):Connect(function(instance: Instance)
		if prompt ~= nil and prompt.Parent == instance then
			task.defer(refreshPrompt)
		end
	end)
end

function ShopUI:Start()
	buildChip()
	refreshPrompt()

	Remotes.GetEvent("ShopGrant").OnClientEvent:Connect(onShopGrant)
	Remotes.GetEvent("ShiftState").OnClientEvent:Connect(onShiftState)
end

return ShopUI
