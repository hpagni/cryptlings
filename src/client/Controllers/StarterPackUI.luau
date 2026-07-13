--!strict
-- CRYPTLINGS: NIGHT SHIFT — StarterPackUI (Stage 6, module shop-ui).
-- The first-purchase break (SOP §4.3): the server fires StarterPackOffer
-- {expiresAt} exactly once, on the player's SECOND successful extraction
-- (they've felt the loop, have boxes banked, the 3/day cap has just bitten).
-- This controller renders it:
--   * One-time modal — "NIGHT SHIFT STARTER PACK — 99 R$" (price from the
--     Price Ladder of Record, never hardcoded): contents list (1 Foreman's
--     Key + 2 extra openings + the exclusive Misprint Trophy), the key's
--     VAULT-CASE ODDS TABLE INLINE before any purchase path (§8.1
--     pre-purchase disclosure — the pack contains a key, so randomness is
--     disclosed on the offer itself), "ONE-TIME OFFER" badge and a live 24h
--     countdown to expiresAt.
--   * Dismissible and it NEVER re-blocks: after dismiss the offer collapses
--     to a small pulsing HUD badge with the countdown; tapping the badge
--     reopens the modal; at expiresAt everything disappears forever.
--   * Buy -> Shop.RequestStarterPackPrompt (the SERVER raises the Marketplace
--     prompt after re-validating one-per-account + compliance). A ShopGrant
--     for STARTER_PACK retires the offer (ShopUI shows the success toast).
--   * Compliance fail-closed (§8.1): the pack contains a Foreman's Key
--     (paid-random, indirect), so before first showing the offer this
--     controller confirms Shop.GetCatalog reports randomRestricted=false. No
--     answer, or restricted=true -> the offer is ignored entirely.
--   * If the offer lands mid-run (extraction while the shift is still
--     Active), the modal defers to the next non-Active shift state — the
--     pitch never interrupts play.
--   * Odds rows render from the server catalog's STARTER_PACK entry when
--     available (same RarityTable of record as the hub board), falling back
--     to the GetOddsTable remote for the Tier 3 vault tier.
--
-- Mobile-first (§3.2/§G): centered portrait-safe card with internal scroll,
-- every tap target >= 44px.
--
-- Public API (Controllers.Get("StarterPackUI")):
--   StarterPackUI.IsOfferActive() -> boolean

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConstants = require(Shared:WaitForChild("Config"):WaitForChild("GameConstants"))
local RarityTable = require(Shared:WaitForChild("Config"):WaitForChild("RarityTable"))
local Remotes = require(Shared:WaitForChild("Net"):WaitForChild("Remotes"))
local PriceLadder = require(Shared:WaitForChild("Economy"):WaitForChild("PriceLadder"))
local Types = require(Shared:WaitForChild("Types"))

local LocalPlayer = Players.LocalPlayer

--------------------------------------------------------------------------------
-- Tuning (cosmetic, this module's domain)
--------------------------------------------------------------------------------

local SKU = "STARTER_PACK"
local VAULT_TIER = GameConstants.VAULT_CASE_TIER -- the key opens a Tier 3 vault case (§F)

-- Touch sizing (§G gate).
local MIN_TOUCH_PX = GameConstants.MOBILE_MIN_TOUCH_TARGET_PX -- 44
local BUY_HEIGHT_PX = math.max(MIN_TOUCH_PX, 52)
local DISMISS_HEIGHT_PX = math.max(MIN_TOUCH_PX, 46)
local BADGE_WIDTH_PX = 132
local BADGE_HEIGHT_PX = math.max(MIN_TOUCH_PX, 48)

-- Modal card: portrait-safe — width/height capped, contents scroll.
local CARD_MAX_WIDTH_PX = 380
local CARD_MAX_HEIGHT_PX = 560
local CARD_POP_SECONDS = 0.18

local ODDS_ROW_HEIGHT_PX = 22
local CONTENT_ROW_HEIGHT_PX = 26

local COUNTDOWN_TICK_SECONDS = 0.25
local FETCH_TIMEOUT_SECONDS = 6

-- Badge pulse.
local PULSE_SECONDS = 0.9
local PULSE_SCALE = 1.06

-- Palette (matches ShopUI/LockerUI greybox chrome).
local COLOR_PANEL = Color3.fromRGB(18, 20, 24)
local COLOR_PANEL_RAISED = Color3.fromRGB(30, 33, 39)
local COLOR_TEXT = Color3.fromRGB(235, 238, 240)
local COLOR_TEXT_DIM = Color3.fromRGB(160, 166, 172)
local COLOR_GOLD = Color3.fromRGB(235, 190, 52)
local COLOR_SCRIM = Color3.fromRGB(8, 9, 12)
local COLOR_FALLBACK = Color3.fromRGB(178, 178, 178)

-- Above the shop sheet (17) and the unboxing theater (20), below OddsUI (24)
-- and broadcasts (40). Badge rides low like the HUD chips.
local MODAL_DISPLAY_ORDER = 22
local BADGE_DISPLAY_ORDER = 9

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local StarterPackUI = {}

local offerExpiresAt: number? = nil -- nil = no live offer
local offerRetired = false -- purchased or expired -> gone forever
local modalAutoShown = false -- the modal auto-pops exactly once
local pendingAutoShow = false -- offer arrived mid-run; pop when the run ends
local complianceChecked = false -- catalog said randomRestricted=false
local shiftStateName = "Intermission"
local buyInFlight = false
local tickToken = 0

local oddsRows: { Types.OddsRow }? = nil
local oddsFetchInFlight = false

local modal: any = nil -- modal refs (lazy)
local badge: any = nil -- HUD badge refs (lazy)

local registryRef: any = nil -- Controllers registry (CursorUnlock lookup)

--------------------------------------------------------------------------------
-- Small helpers
--------------------------------------------------------------------------------

-- R4-2: free the first-person cursor while the modal is up. Safe registry
-- lookup, nil-guarded no-op until CursorUnlock registers; token = module name.
-- Every path that hides the modal (dismiss, scrim tap, shift-start force-close,
-- retireOffer on purchase/expiry) funnels through the shared hide path, which
-- releases the token before the gui goes dark.
local function setCursorUnlocked(unlocked: boolean)
	if registryRef == nil or type(registryRef.Get) ~= "function" then
		return
	end
	local cursorUnlock = registryRef.Get("CursorUnlock")
	if cursorUnlock == nil then
		return
	end
	if unlocked then
		cursorUnlock.acquire("StarterPackUI")
	else
		cursorUnlock.release("StarterPackUI")
	end
end

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

-- Same exact-percent formatting as ShopUI/OddsUI/hub board (§8.1).
local function formatPct(pct: number): string
	if pct == math.floor(pct) then
		return string.format("%d%%", pct)
	end
	local text = string.format("%.2f", pct)
	text = string.gsub(text, "0+$", "")
	text = string.gsub(text, "%.$", "")
	return text .. "%"
end

local function formatHMS(seconds: number): string
	local total = math.max(0, math.floor(seconds))
	return string.format("%02d:%02d:%02d", total // 3600, (total % 3600) // 60, total % 60)
end

local function packPriceRobux(): number?
	local ok, row = pcall(function()
		return (PriceLadder :: any).GetRow(SKU)
	end)
	if ok and type(row) == "table" and type(row.priceRobux) == "number" then
		return row.priceRobux
	end
	return nil
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

-- Guarded RemoteFunction invoke: returns the reply or nil after the timeout —
-- an unbound remote (mid-construction server) can never hang the client.
local function guardedInvoke(remoteName: string, timeoutSeconds: number, ...: any): any
	local args = table.pack(...)
	local response: any = nil
	local done = false
	task.spawn(function()
		local ok, result = pcall(function()
			return Remotes.GetFunction(remoteName):InvokeServer(table.unpack(args, 1, args.n))
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
	return response
end

--------------------------------------------------------------------------------
-- Odds (server of record; §8.1 — must match the hub board)
--------------------------------------------------------------------------------

local renderOddsRows: () -> () -- forward-declared

-- Prefer the catalog's STARTER_PACK entry odds (the exact §8.1 disclosure the
-- shop shows); fall back to GetOddsTable(3) — both feed from RarityTable.
local function fetchOdds()
	if oddsRows ~= nil or oddsFetchInFlight then
		return
	end
	oddsFetchInFlight = true
	task.spawn(function()
		local catalog = guardedInvoke("Shop.GetCatalog", FETCH_TIMEOUT_SECONDS)
		if type(catalog) == "table" and type(catalog.items) == "table" then
			for _, entry in catalog.items :: { any } do
				if type(entry) == "table" and entry.sku == SKU and isOddsArray(entry.odds) then
					oddsRows = entry.odds
					break
				end
			end
		end
		if oddsRows == nil then
			local table3 = guardedInvoke("GetOddsTable", FETCH_TIMEOUT_SECONDS, VAULT_TIER)
			if isOddsArray(table3) then
				oddsRows = table3
			end
		end
		oddsFetchInFlight = false
		renderOddsRows()
	end)
end

--------------------------------------------------------------------------------
-- Offer retirement
--------------------------------------------------------------------------------

local hideModal: () -> () -- forward-declared

local function retireOffer()
	offerRetired = true
	offerExpiresAt = nil
	pendingAutoShow = false
	tickToken += 1
	hideModal()
	if badge ~= nil then
		badge.gui:Destroy()
		badge = nil
	end
	if modal ~= nil then
		modal.gui:Destroy()
		modal = nil
	end
end

local function secondsLeft(): number
	local expiresAt = offerExpiresAt
	if expiresAt == nil then
		return 0
	end
	return expiresAt - os.time()
end

--------------------------------------------------------------------------------
-- HUD badge (small, pulsing, right rail; gone forever at expiresAt)
--------------------------------------------------------------------------------

local showModal: () -> () -- forward-declared

local function updateBadgeVisibility()
	if badge ~= nil then
		badge.button.Visible = shiftStateName ~= "Active" and not (modal ~= nil and modal.gui.Enabled)
	end
end

local function buildBadge()
	if badge ~= nil or offerRetired then
		return
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = "StarterPackBadge"
	gui.ResetOnSpawn = false
	gui.ScreenInsets = Enum.ScreenInsets.DeviceSafeInsets
	gui.DisplayOrder = BADGE_DISPLAY_ORDER

	local button = Instance.new("TextButton")
	button.Name = "Badge"
	button.AnchorPoint = Vector2.new(1, 0.5)
	button.Position = UDim2.new(1, -8, 0.42, 0) -- right rail, clear of the bottom-right touch buttons
	button.Size = UDim2.fromOffset(BADGE_WIDTH_PX, BADGE_HEIGHT_PX)
	button.BackgroundColor3 = COLOR_PANEL
	button.BackgroundTransparency = 0.15
	button.BorderSizePixel = 0
	button.Text = ""
	button.AutoButtonColor = true
	button.Parent = gui
	makeRound(button, 12)

	local stroke = Instance.new("UIStroke")
	stroke.Color = COLOR_GOLD
	stroke.Thickness = 1.5
	stroke.Transparency = 0.2
	stroke.Parent = button

	local scale = Instance.new("UIScale")
	scale.Parent = button

	local caption = makeLabel("Caption", 11, true)
	caption.Position = UDim2.fromOffset(0, 6)
	caption.Size = UDim2.new(1, 0, 0, 14)
	caption.TextColor3 = COLOR_GOLD
	caption.Text = "STARTER PACK"
	caption.Parent = button

	local countdown = makeLabel("Countdown", 14, true)
	countdown.Position = UDim2.new(0, 0, 1, -22)
	countdown.Size = UDim2.new(1, 0, 0, 16)
	countdown.Text = "--:--:--"
	countdown.Parent = button

	badge = { gui = gui, button = button, countdown = countdown, scale = scale, stroke = stroke }
	gui.Parent = LocalPlayer:WaitForChild("PlayerGui")

	button.Activated:Connect(function()
		if not offerRetired and shiftStateName ~= "Active" then
			showModal()
		end
	end)

	-- Gentle breathe pulse — visible, not shouty.
	task.spawn(function()
		while badge ~= nil and badge.gui.Parent ~= nil do
			local grow = TweenService:Create(
				scale,
				TweenInfo.new(PULSE_SECONDS, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
				{ Scale = PULSE_SCALE }
			)
			grow:Play()
			grow.Completed:Wait()
			if badge == nil or badge.gui.Parent == nil then
				break
			end
			local shrink = TweenService:Create(
				scale,
				TweenInfo.new(PULSE_SECONDS, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
				{ Scale = 1 }
			)
			shrink:Play()
			shrink.Completed:Wait()
		end
	end)
	updateBadgeVisibility()
end

--------------------------------------------------------------------------------
-- Countdown loop (drives both the modal timer and the badge; expiry retires)
--------------------------------------------------------------------------------

local function startTickLoop()
	tickToken += 1
	local token = tickToken
	task.spawn(function()
		while token == tickToken and not offerRetired do
			local left = secondsLeft()
			if left <= 0 then
				retireOffer() -- gone forever (§4.3: 24h visible timer, then out)
				return
			end
			local text = formatHMS(left)
			if badge ~= nil then
				badge.countdown.Text = text
			end
			if modal ~= nil and modal.gui.Enabled then
				modal.countdown.Text = `ENDS IN {text}`
			end
			task.wait(COUNTDOWN_TICK_SECONDS)
		end
	end)
end

--------------------------------------------------------------------------------
-- Modal construction (lazy)
--------------------------------------------------------------------------------

local function buildContentRow(parent: GuiObject, order: number, text: string)
	local row = Instance.new("Frame")
	row.Name = `Content{order}`
	row.Size = UDim2.new(1, 0, 0, CONTENT_ROW_HEIGHT_PX)
	row.BackgroundTransparency = 1
	row.LayoutOrder = order

	local tick = makeLabel("Tick", 14, true)
	tick.Position = UDim2.fromOffset(0, 0)
	tick.Size = UDim2.fromOffset(18, CONTENT_ROW_HEIGHT_PX)
	tick.TextColor3 = COLOR_GOLD
	tick.Text = "+"
	tick.Parent = row

	local label = makeLabel("Text", 13, false)
	label.Position = UDim2.fromOffset(22, 0)
	label.Size = UDim2.new(1, -22, 1, 0)
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextWrapped = true
	label.Text = text
	label.Parent = row

	row.Parent = parent
end

local function buildModal()
	if modal ~= nil then
		return
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = "StarterPackUI"
	gui.ResetOnSpawn = false
	gui.ScreenInsets = Enum.ScreenInsets.DeviceSafeInsets
	gui.DisplayOrder = MODAL_DISPLAY_ORDER
	gui.Enabled = false
	-- Sibling stacking: default-ZIndex body rows must render above the ZIndex-2 card.
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	-- Scrim: tapping outside dismisses to the badge — never re-blocks.
	local scrim = Instance.new("TextButton")
	scrim.Name = "Scrim"
	scrim.Size = UDim2.fromScale(1, 1)
	scrim.BackgroundColor3 = COLOR_SCRIM
	scrim.BackgroundTransparency = 0.4
	scrim.BorderSizePixel = 0
	scrim.Text = ""
	scrim.AutoButtonColor = false
	scrim.ZIndex = 1
	scrim.Parent = gui

	local card = Instance.new("Frame")
	card.Name = "Card"
	card.AnchorPoint = Vector2.new(0.5, 0.5)
	card.Position = UDim2.fromScale(0.5, 0.5)
	card.Size = UDim2.new(1, -24, 0.92, 0)
	card.BackgroundColor3 = COLOR_PANEL
	card.BorderSizePixel = 0
	card.ZIndex = 2
	card.Parent = gui
	makeRound(card, 18)
	local sizeCap = Instance.new("UISizeConstraint")
	sizeCap.MaxSize = Vector2.new(CARD_MAX_WIDTH_PX, CARD_MAX_HEIGHT_PX)
	sizeCap.Parent = card
	local cardStroke = Instance.new("UIStroke")
	cardStroke.Color = COLOR_GOLD
	cardStroke.Thickness = 2
	cardStroke.Transparency = 0.25
	cardStroke.Parent = card
	local cardScale = Instance.new("UIScale")
	cardScale.Parent = card
	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, 16)
	padding.PaddingRight = UDim.new(0, 16)
	padding.PaddingTop = UDim.new(0, 14)
	padding.PaddingBottom = UDim.new(0, 14)
	padding.Parent = card

	-- ONE-TIME OFFER badge + live countdown (§4.3).
	local offerBadge = makeLabel("OneTime", 11, true)
	offerBadge.BackgroundTransparency = 0
	offerBadge.BackgroundColor3 = COLOR_GOLD
	offerBadge.TextColor3 = COLOR_PANEL
	offerBadge.Position = UDim2.fromOffset(0, 0)
	offerBadge.Size = UDim2.fromOffset(118, 22)
	offerBadge.Text = "ONE-TIME OFFER"
	offerBadge.ZIndex = 3
	offerBadge.Parent = card
	makeRound(offerBadge, 11)

	local countdown = makeLabel("Countdown", 13, true)
	countdown.AnchorPoint = Vector2.new(1, 0)
	countdown.Position = UDim2.new(1, 0, 0, 2)
	countdown.Size = UDim2.fromOffset(140, 18)
	countdown.TextXAlignment = Enum.TextXAlignment.Right
	countdown.TextColor3 = COLOR_GOLD
	countdown.Text = "ENDS IN --:--:--"
	countdown.ZIndex = 3
	countdown.Parent = card

	local title = makeLabel("Title", 21, true)
	title.Position = UDim2.fromOffset(0, 30)
	title.Size = UDim2.new(1, 0, 0, 26)
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Text = "NIGHT SHIFT STARTER PACK"
	title.TextWrapped = true
	title.ZIndex = 3
	title.Parent = card

	local price = packPriceRobux()
	local priceLabel = makeLabel("Price", 17, true)
	priceLabel.Position = UDim2.fromOffset(0, 58)
	priceLabel.Size = UDim2.new(1, 0, 0, 20)
	priceLabel.TextXAlignment = Enum.TextXAlignment.Left
	priceLabel.TextColor3 = COLOR_GOLD
	priceLabel.Text = if price ~= nil then `{price} R$` else ""
	priceLabel.ZIndex = 3
	priceLabel.Parent = card

	-- Scrollable middle: contents list + the key's odds table.
	local buttonsBlock = BUY_HEIGHT_PX + 8 + DISMISS_HEIGHT_PX
	local scroll = Instance.new("ScrollingFrame")
	scroll.Name = "Body"
	scroll.Position = UDim2.fromOffset(0, 86)
	scroll.Size = UDim2.new(1, 0, 1, -(86 + buttonsBlock + 10))
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.ScrollBarThickness = 5
	scroll.ScrollBarImageColor3 = COLOR_PANEL_RAISED
	scroll.ScrollingDirection = Enum.ScrollingDirection.Y
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.CanvasSize = UDim2.new()
	scroll.ZIndex = 3
	scroll.Parent = card
	local bodyLayout = Instance.new("UIListLayout")
	bodyLayout.FillDirection = Enum.FillDirection.Vertical
	bodyLayout.Padding = UDim.new(0, 4)
	bodyLayout.SortOrder = Enum.SortOrder.LayoutOrder
	bodyLayout.Parent = scroll

	buildContentRow(scroll, 1, "1× Foreman's Key — opens 1 bonus vault case")
	buildContentRow(scroll, 2, "2× extra daily case-openings")
	buildContentRow(scroll, 3, "Misprint Trophy — exclusive shelf trophy, this pack only")

	-- §8.1: the key's odds, inline, before any purchase path.
	local oddsHeader = makeLabel("OddsHeader", 11, true)
	oddsHeader.Size = UDim2.new(1, 0, 0, 20)
	oddsHeader.TextXAlignment = Enum.TextXAlignment.Left
	oddsHeader.TextColor3 = COLOR_TEXT_DIM
	oddsHeader.Text = "FOREMAN'S KEY — VAULT CASE ODDS"
	oddsHeader.LayoutOrder = 4
	oddsHeader.Parent = scroll

	local oddsList = Instance.new("Frame")
	oddsList.Name = "OddsList"
	oddsList.Size = UDim2.new(1, 0, 0, ODDS_ROW_HEIGHT_PX) -- grows on render
	oddsList.BackgroundTransparency = 1
	oddsList.LayoutOrder = 5
	oddsList.Parent = scroll

	local oddsCaption = makeLabel("OddsCaption", 11, false)
	oddsCaption.Size = UDim2.new(1, 0, 0, 18)
	oddsCaption.TextXAlignment = Enum.TextXAlignment.Left
	oddsCaption.TextColor3 = COLOR_TEXT_DIM
	oddsCaption.Text = "Odds identical to the hub board."
	oddsCaption.LayoutOrder = 6
	oddsCaption.Parent = scroll

	-- Buy + dismiss.
	local buy = Instance.new("TextButton")
	buy.Name = "Buy"
	buy.AnchorPoint = Vector2.new(0.5, 1)
	buy.Position = UDim2.new(0.5, 0, 1, -(DISMISS_HEIGHT_PX + 8))
	buy.Size = UDim2.new(1, 0, 0, BUY_HEIGHT_PX)
	buy.BackgroundColor3 = COLOR_GOLD
	buy.BorderSizePixel = 0
	buy.Font = Enum.Font.GothamBold
	buy.TextSize = 17
	buy.TextColor3 = COLOR_PANEL
	buy.Text = if price ~= nil then `GET THE PACK — {price} R$` else "GET THE PACK"
	buy.ZIndex = 3
	buy.Parent = card
	makeRound(buy, 12)

	local dismiss = Instance.new("TextButton")
	dismiss.Name = "Dismiss"
	dismiss.AnchorPoint = Vector2.new(0.5, 1)
	dismiss.Position = UDim2.fromScale(0.5, 1)
	dismiss.Size = UDim2.new(1, 0, 0, DISMISS_HEIGHT_PX)
	dismiss.BackgroundColor3 = COLOR_PANEL_RAISED
	dismiss.BorderSizePixel = 0
	dismiss.Font = Enum.Font.GothamBold
	dismiss.TextSize = 14
	dismiss.TextColor3 = COLOR_TEXT_DIM
	dismiss.Text = "NOT NOW"
	dismiss.ZIndex = 3
	dismiss.Parent = card
	makeRound(dismiss, 12)

	modal = {
		gui = gui,
		card = card,
		cardScale = cardScale,
		countdown = countdown,
		oddsList = oddsList,
		buy = buy,
		dismiss = dismiss,
	}
	gui.Parent = LocalPlayer:WaitForChild("PlayerGui")

	scrim.Activated:Connect(hideModal)
	dismiss.Activated:Connect(hideModal)
	buy.Activated:Connect(function()
		if buyInFlight or offerRetired then
			return
		end
		buyInFlight = true
		buy.Text = "OPENING PROMPT..."
		task.spawn(function()
			-- The server raises the Marketplace prompt (one-per-account +
			-- compliance re-checked server-side).
			local reply = guardedInvoke("Shop.RequestStarterPackPrompt", FETCH_TIMEOUT_SECONDS)
			buyInFlight = false
			if modal == nil then
				return
			end
			if type(reply) == "table" and reply.ok == true then
				modal.buy.Text = if price ~= nil then `GET THE PACK — {price} R$` else "GET THE PACK"
			else
				modal.buy.Text = "OFFER UNAVAILABLE"
			end
		end)
	end)
end

renderOddsRows = function()
	if modal == nil then
		return
	end
	local list = modal.oddsList :: Frame
	for _, child in list:GetChildren() do
		child:Destroy()
	end

	local rows = oddsRows
	if rows == nil then
		list.Size = UDim2.new(1, 0, 0, ODDS_ROW_HEIGHT_PX)
		local pendingLabel = makeLabel("Pending", 12, false)
		pendingLabel.Size = UDim2.new(1, 0, 0, ODDS_ROW_HEIGHT_PX)
		pendingLabel.TextXAlignment = Enum.TextXAlignment.Left
		pendingLabel.TextColor3 = COLOR_TEXT_DIM
		pendingLabel.Text = "Fetching exact odds..."
		pendingLabel.Parent = list
		return
	end

	list.Size = UDim2.new(1, 0, 0, ODDS_ROW_HEIGHT_PX * #rows)
	for index, row in rows do
		local color = rarityColor(row.rarity)
		local y = (index - 1) * ODDS_ROW_HEIGHT_PX

		local dot = Instance.new("Frame")
		dot.Name = `Dot{index}`
		dot.AnchorPoint = Vector2.new(0, 0.5)
		dot.Position = UDim2.fromOffset(0, y + ODDS_ROW_HEIGHT_PX // 2)
		dot.Size = UDim2.fromOffset(10, 10)
		dot.BackgroundColor3 = color
		dot.BorderSizePixel = 0
		dot.Parent = list
		local dotCorner = Instance.new("UICorner")
		dotCorner.CornerRadius = UDim.new(1, 0)
		dotCorner.Parent = dot

		local nameLabel = makeLabel(`Rarity{index}`, 13, true)
		nameLabel.Position = UDim2.fromOffset(18, y)
		nameLabel.Size = UDim2.new(1, -(18 + 76), 0, ODDS_ROW_HEIGHT_PX)
		nameLabel.TextXAlignment = Enum.TextXAlignment.Left
		nameLabel.TextColor3 = color
		nameLabel.Text = row.rarity
		nameLabel.Parent = list

		local pctLabel = makeLabel(`Pct{index}`, 13, true)
		pctLabel.AnchorPoint = Vector2.new(1, 0)
		pctLabel.Position = UDim2.new(1, 0, 0, y)
		pctLabel.Size = UDim2.fromOffset(72, ODDS_ROW_HEIGHT_PX)
		pctLabel.TextXAlignment = Enum.TextXAlignment.Right
		pctLabel.Text = formatPct(row.pct)
		pctLabel.Parent = list
	end
end

--------------------------------------------------------------------------------
-- Show / hide
--------------------------------------------------------------------------------

showModal = function()
	if offerRetired or offerExpiresAt == nil then
		return
	end
	buildModal()
	fetchOdds()
	renderOddsRows()
	modal.countdown.Text = `ENDS IN {formatHMS(secondsLeft())}`
	modal.gui.Enabled = true
	setCursorUnlocked(true) -- R4-2: cursor free while the modal is up
	modal.cardScale.Scale = 0.9
	TweenService:Create(
		modal.cardScale,
		TweenInfo.new(CARD_POP_SECONDS, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Scale = 1 }
	):Play()
	updateBadgeVisibility()
end

hideModal = function()
	setCursorUnlocked(false) -- R4-2: first person re-locks next frame
	if modal ~= nil then
		modal.gui.Enabled = false
	end
	-- Dismiss never re-blocks: the offer lives on as the pulsing badge.
	if not offerRetired and offerExpiresAt ~= nil then
		buildBadge()
	end
	updateBadgeVisibility()
end

--------------------------------------------------------------------------------
-- Server event handlers
--------------------------------------------------------------------------------

-- Fail-closed compliance check (§8.1): the pack contains a Foreman's Key, so
-- the offer only ever shows after the server catalog confirms this player is
-- NOT random-restricted. No catalog, no offer.
local function verifyCompliance(): boolean
	if complianceChecked then
		return true
	end
	local catalog = guardedInvoke("Shop.GetCatalog", FETCH_TIMEOUT_SECONDS)
	if type(catalog) == "table" and catalog.randomRestricted == false then
		complianceChecked = true
		return true
	end
	return false
end

local function presentOffer()
	if offerRetired or offerExpiresAt == nil then
		return
	end
	startTickLoop()
	if modalAutoShown then
		buildBadge() -- repeat offers just keep the badge ticking
		return
	end
	if shiftStateName == "Active" then
		pendingAutoShow = true -- never interrupt a run; pop on clock-out
		return
	end
	modalAutoShown = true
	showModal()
end

local function onStarterPackOffer(payload: any)
	if offerRetired then
		return
	end
	if type(payload) ~= "table" or type(payload.expiresAt) ~= "number" then
		return
	end
	if payload.expiresAt - os.time() <= 0 then
		return
	end
	task.spawn(function()
		if not verifyCompliance() then
			warn("[StarterPackUI] offer suppressed — compliance not confirmed (fail-closed, §8.1)")
			return
		end
		if offerRetired then
			return
		end
		offerExpiresAt = payload.expiresAt
		presentOffer()
	end)
end

local function onShopGrant(payload: any)
	if type(payload) == "table" and payload.sku == SKU then
		retireOffer() -- bought: ShopUI's toast handles the celebration
	end
end

local function onShiftState(payload: any)
	if type(payload) ~= "table" or type(payload.state) ~= "string" then
		return
	end
	shiftStateName = payload.state
	if shiftStateName == "Active" then
		if modal ~= nil and modal.gui.Enabled then
			hideModal() -- collapse to the badge; never blocks play
		end
	elseif pendingAutoShow and not offerRetired and offerExpiresAt ~= nil then
		pendingAutoShow = false
		if not modalAutoShown then
			modalAutoShown = true
			showModal()
		end
	end
	updateBadgeVisibility()
end

--------------------------------------------------------------------------------
-- Public API + lifecycle
--------------------------------------------------------------------------------

function StarterPackUI.IsOfferActive(): boolean
	return offerExpiresAt ~= nil and not offerRetired and secondsLeft() > 0
end

function StarterPackUI:Init(registry: any)
	registryRef = registry -- CursorUnlock lookup (R4-2); nothing yielding here
end

function StarterPackUI:Start()
	Remotes.GetEvent("StarterPackOffer").OnClientEvent:Connect(onStarterPackOffer)
	Remotes.GetEvent("ShopGrant").OnClientEvent:Connect(onShopGrant)
	Remotes.GetEvent("ShiftState").OnClientEvent:Connect(onShiftState)
end

return StarterPackUI
