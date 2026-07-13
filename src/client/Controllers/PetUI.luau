--!strict
-- CRYPTLINGS: NIGHT SHIFT — PetUI (equippable pets, minimal sheet).
--   * Entry point: a persistent "PETS" HUD chip on the left rail, parked under
--     the shop chip (locker 0.56+0 -> shop 0.56+74 -> pets 0.56+150).
--   * Sheet: a simple bottom list of OWNED cryptlings (Pet.GetState.ownedIds —
--     the server is the single collection source here) with EQUIP/UNEQUIP per
--     row, plus the PET_TREATS upgrade row ("TREAT LV n/3" + a 249 R$ UPGRADE
--     button; "MAX" at the cap).
--   * Purchase: the EXIT_WARP quick-buy pattern, implemented HERE (contract:
--     InputController is not edited) — pull Shop.GetCatalog for the PET_TREATS
--     assetId and PromptProductPurchase; assetId 0 (Creator Dashboard not
--     wired) -> polite refusal, no prompt. The grant lands via the receipt
--     path; ShopUI's global ShopGrant toast announces it and this controller
--     just refreshes its state.
--   * Perk copy comes from Shared.Logic.PetPerks — the exact math PetService
--     applies — so the sheet can never advertise numbers the server won't
--     grant. Only the SHIPPED maxHealth perk is advertised (speedBonus is an
--     advisory attribute, see GameConstants.PET_PERKS doc).
--
-- Every ScreenGui sets ZIndexBehavior.Sibling (Instance.new defaults to
-- Global, the known z-tie footgun in this codebase).
--
-- Public API (Controllers.Get("PetUI")):
--   PetUI.Open() / PetUI.Close() / PetUI.Toggle() / PetUI.IsOpen()

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConstants = require(Shared:WaitForChild("Config"):WaitForChild("GameConstants"))
local RarityTable = require(Shared:WaitForChild("Config"):WaitForChild("RarityTable"))
local PetPerks = require(Shared:WaitForChild("Logic"):WaitForChild("PetPerks"))
local Remotes = require(Shared:WaitForChild("Net"):WaitForChild("Remotes"))

local LocalPlayer = Players.LocalPlayer

--------------------------------------------------------------------------------
-- Tuning (cosmetic, this module's domain)
--------------------------------------------------------------------------------

local SKU_PET_TREATS = "PET_TREATS"

local MIN_TOUCH_PX = GameConstants.MOBILE_MIN_TOUCH_TARGET_PX -- 44
local CLOSE_PX = math.max(MIN_TOUCH_PX, 48)
local CHIP_WIDTH_PX = 84
local CHIP_HEIGHT_PX = math.max(MIN_TOUCH_PX, 68)
-- Left rail: locker chip at (8, 0.56, +0), shop chip at +74; next slot.
local CHIP_POSITION = UDim2.new(0, 8, 0.56, 150)

local SHEET_HEIGHT_SCALE = 0.7
local SHEET_MAX_WIDTH_PX = 560
local SHEET_SLIDE_SECONDS = 0.18

local ROW_HEIGHT_PX = 64
local ROW_GAP_PX = 8
local ROW_PAD_PX = 12
local EQUIP_WIDTH_PX = 104
local EQUIP_HEIGHT_PX = math.max(MIN_TOUCH_PX, 48)

local STATE_FETCH_TIMEOUT_SECONDS = 6

-- Palette (matches the ShopUI/LockerUI greybox chrome).
local COLOR_PANEL = Color3.fromRGB(18, 20, 24)
local COLOR_PANEL_RAISED = Color3.fromRGB(30, 33, 39)
local COLOR_CARD = Color3.fromRGB(26, 29, 34)
local COLOR_TEXT = Color3.fromRGB(235, 238, 240)
local COLOR_TEXT_DIM = Color3.fromRGB(160, 166, 172)
local COLOR_ACCENT = Color3.fromRGB(80, 220, 120)
local COLOR_GOLD = Color3.fromRGB(235, 190, 52)
local COLOR_SCRIM = Color3.fromRGB(8, 9, 12)
local COLOR_PIP_EMPTY = Color3.fromRGB(60, 64, 70)
local COLOR_FALLBACK = Color3.fromRGB(178, 178, 178)

-- DisplayOrder 18: above the shop sheet (17), below the unboxing theater (20).
local DISPLAY_ORDER = 18
local CHIP_DISPLAY_ORDER = DISPLAY_ORDER - 4

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local PetUI = {}

type PetStatePayload = {
	equippedId: string,
	upgradeLevel: number,
	ownedIds: { string },
	perk: any?,
	shiftPay: number?, -- current spendable shift pay
	nextPayCost: number?, -- shift-pay cost of the next level (nil at the cap)
}

local isOpen = false
local petState: PetStatePayload? = nil
local fetchInFlight = false
local equipBusy = false
local upgradeBusy = false

local ui: any = nil -- sheet refs (lazy)

local registryRef: any = nil -- Controllers registry (CursorUnlock lookup)

--------------------------------------------------------------------------------
-- Small helpers
--------------------------------------------------------------------------------

-- R4-2: free the first-person cursor while the sheet is open. Safe registry
-- lookup, nil-guarded no-op until CursorUnlock registers; token = module name.
-- Every path that hides the sheet funnels through PetUI.Close, which releases.
local function setCursorUnlocked(unlocked: boolean)
	if registryRef == nil or type(registryRef.Get) ~= "function" then
		return
	end
	local cursorUnlock = registryRef.Get("CursorUnlock")
	if cursorUnlock == nil then
		return
	end
	if unlocked then
		cursorUnlock.acquire("PetUI")
	else
		cursorUnlock.release("PetUI")
	end
end

-- R7 Fix #2: kid-friendly clock-in reminder via RunHUD's shared toast. Safe
-- registry lookup, nil-guarded no-op until RunHUD registers.
local function showClockInReminder()
	if registryRef == nil or type(registryRef.Get) ~= "function" then
		return
	end
	local runHud = registryRef.Get("RunHUD")
	if runHud ~= nil and type(runHud.ShowToast) == "function" then
		pcall(runHud.ShowToast, GameConstants.EMPTY_STATE.CLOCK_IN_REMINDER, 3)
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

local function trimNum(value: number): string
	local text = string.format("%.2f", value)
	text = string.gsub(text, "0+$", "")
	text = string.gsub(text, "%.$", "")
	return text
end

-- Per-pet perk summary, e.g. "+12 HP", "+2 Spd", "+15% PVP · +2 Box". Only the
-- pet's active dimensions show (varies by perk kind).
local function formatPerk(perk: any): string
	if type(perk) ~= "table" then
		return ""
	end
	local parts: { string } = {}
	if (perk.maxHealth or 0) > 0 then
		table.insert(parts, `+{trimNum(perk.maxHealth)} HP`)
	end
	if (perk.speedBonus or 0) > 0 then
		table.insert(parts, `+{trimNum(perk.speedBonus)} Spd`)
	end
	if (perk.pvpStrength or 0) > 0 then
		table.insert(parts, `+{math.floor(perk.pvpStrength * 100 + 0.5)}% PVP`)
	end
	if (perk.carryBonus or 0) > 0 then
		table.insert(parts, `+{math.floor(perk.carryBonus)} Box`)
	end
	return table.concat(parts, " · ")
end

local function isStateShaped(payload: any): boolean
	return type(payload) == "table"
		and type(payload.equippedId) == "string"
		and type(payload.upgradeLevel) == "number"
		and type(payload.ownedIds) == "table"
end

--------------------------------------------------------------------------------
-- State fetch (guarded: an unbound/slow remote can never hang the UI)
--------------------------------------------------------------------------------

local renderSheet: () -> () -- forward-declared

local function fetchState(timeoutSeconds: number): PetStatePayload?
	local response: any = nil
	local done = false
	task.spawn(function()
		local ok, result = pcall(function()
			return Remotes.GetFunction("Pet.GetState"):InvokeServer()
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
	if isStateShaped(response) then
		return response :: PetStatePayload
	end
	return nil
end

local function requestStateRefresh()
	if fetchInFlight then
		return
	end
	fetchInFlight = true
	task.spawn(function()
		local fresh = fetchState(STATE_FETCH_TIMEOUT_SECONDS)
		fetchInFlight = false
		if fresh ~= nil then
			petState = fresh
			if ui ~= nil and isOpen then
				renderSheet()
			end
		elseif ui ~= nil and isOpen and petState == nil then
			ui.emptyLabel.Text = "The pet locker isn't answering — try again in a moment."
			ui.emptyLabel.Visible = true
		end
	end)
end

--------------------------------------------------------------------------------
-- Actions
--------------------------------------------------------------------------------

local function invokeEquip(cryptlingId: string)
	if equipBusy then
		return
	end
	equipBusy = true
	task.spawn(function()
		local ok, result = pcall(function()
			return Remotes.GetFunction("Pet.Equip"):InvokeServer(cryptlingId)
		end)
		equipBusy = false
		if not ok then
			warn(`[PetUI] Pet.Equip invoke failed: {result}`)
			return
		end
		if type(result) == "table" and result.ok ~= true then
			warn(`[PetUI] Pet.Equip refused: {tostring(result.err)}`)
		end
		requestStateRefresh()
	end)
end

-- Primary pet upgrade path: spend shift pay (escalating cost) via the server.
-- The Robux alternative (PET_TREATS) lives in the Supply Shop, not here.
local function invokeUpgradeWithPay()
	if upgradeBusy then
		return
	end
	upgradeBusy = true
	task.spawn(function()
		local ok, reply = pcall(function()
			return Remotes.GetFunction("Pet.UpgradeWithPay"):InvokeServer()
		end)
		if ok and type(reply) == "table" and reply.ok == true then
			requestStateRefresh() -- pull the new level + remaining pay
		end
		upgradeBusy = false
	end)
end

--------------------------------------------------------------------------------
-- Sheet rendering
--------------------------------------------------------------------------------

local function buildRow(cryptlingId: string, state: PetStatePayload, order: number): Frame?
	local def: any = RarityTable.GetCryptling(cryptlingId)
	if def == nil then
		return nil
	end
	local equipped = state.equippedId == cryptlingId
	local perk = PetPerks.GetPerkForId(def.rarity, state.upgradeLevel, def.id)

	local row = Instance.new("Frame")
	row.Name = `Row_{cryptlingId}`
	row.Size = UDim2.new(1, 0, 0, ROW_HEIGHT_PX)
	row.BackgroundColor3 = COLOR_CARD
	row.BorderSizePixel = 0
	row.LayoutOrder = order
	makeRound(row, 12)

	if equipped then
		local stroke = Instance.new("UIStroke")
		stroke.Color = COLOR_ACCENT
		stroke.Thickness = 1.5
		stroke.Transparency = 0.25
		stroke.Parent = row
	end

	local name = makeLabel("PetName", 16, true)
	name.Position = UDim2.fromOffset(ROW_PAD_PX, 10)
	name.Size = UDim2.new(1, -(ROW_PAD_PX * 3 + EQUIP_WIDTH_PX), 0, 20)
	name.TextXAlignment = Enum.TextXAlignment.Left
	name.TextColor3 = rarityColor(def.rarity)
	name.Text = def.name
	name.Parent = row

	local perkLabel = makeLabel("Perk", 12, false)
	perkLabel.Position = UDim2.fromOffset(ROW_PAD_PX, 32)
	perkLabel.Size = UDim2.new(1, -(ROW_PAD_PX * 3 + EQUIP_WIDTH_PX), 0, 16)
	perkLabel.TextXAlignment = Enum.TextXAlignment.Left
	perkLabel.TextColor3 = COLOR_TEXT_DIM
	perkLabel.Text = if perk ~= nil then `{def.rarity} — {formatPerk(perk)}` else def.rarity
	perkLabel.Parent = row

	local action = Instance.new("TextButton")
	action.Name = "Action"
	action.AnchorPoint = Vector2.new(1, 0.5)
	action.Position = UDim2.new(1, -ROW_PAD_PX, 0.5, 0)
	action.Size = UDim2.fromOffset(EQUIP_WIDTH_PX, EQUIP_HEIGHT_PX)
	action.BorderSizePixel = 0
	action.Font = Enum.Font.GothamBold
	action.TextSize = 14
	action.AutoButtonColor = true
	action.Parent = row
	makeRound(action, 10)
	if equipped then
		action.BackgroundColor3 = COLOR_PANEL_RAISED
		action.TextColor3 = COLOR_TEXT_DIM
		action.Text = "UNEQUIP"
	else
		action.BackgroundColor3 = COLOR_ACCENT
		action.TextColor3 = COLOR_PANEL
		action.Text = "EQUIP"
	end
	action.Activated:Connect(function()
		invokeEquip(if equipped then "" else cryptlingId)
	end)

	return row
end

renderSheet = function()
	if ui == nil then
		return
	end
	for _, child in ui.list:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end

	local state = petState
	if state == nil then
		ui.emptyLabel.Text = "Opening the pet locker..."
		ui.emptyLabel.Visible = true
		ui.upgradeButton.Visible = false
		ui.levelLabel.Text = ""
		return
	end

	-- Upgrade row: level readout + the shift-pay upgrade button (escalating cost;
	-- "MAX" badge at the cap). The Robux alternative is sold in the Supply Shop.
	local level = PetPerks.ClampLevel(state.upgradeLevel)
	local cap = GameConstants.PET_UPGRADE_MAX_LEVEL
	ui.levelLabel.Text = `PET LV {level}/{cap} — perks x{string.format("%.2f", PetPerks.Multiplier(level))}`
	ui.upgradeButton.Visible = true
	local nextCost = state.nextPayCost
	if level >= cap or type(nextCost) ~= "number" then
		ui.upgradeButton.Text = "MAX"
		ui.upgradeButton.BackgroundColor3 = COLOR_PANEL_RAISED
		ui.upgradeButton.TextColor3 = COLOR_ACCENT
		ui.upgradeButton.AutoButtonColor = false
	else
		local canAfford = (state.shiftPay or 0) >= nextCost
		ui.upgradeButton.Text = `UPGRADE — {nextCost} PAY`
		ui.upgradeButton.BackgroundColor3 = if canAfford then COLOR_GOLD else COLOR_PANEL_RAISED
		ui.upgradeButton.TextColor3 = if canAfford then COLOR_PANEL else COLOR_TEXT_DIM
		ui.upgradeButton.AutoButtonColor = canAfford
	end

	local count = 0
	for _, cryptlingId in state.ownedIds do
		if type(cryptlingId) == "string" then
			local row = buildRow(cryptlingId, state, count + 1)
			if row ~= nil then
				count += 1
				row.Parent = ui.list
			end
		end
	end

	ui.emptyLabel.Visible = count == 0
	if count == 0 then
		ui.emptyLabel.Text = GameConstants.EMPTY_STATE.PETS_EMPTY
	end
end

--------------------------------------------------------------------------------
-- HUD chip (left rail, under the shop chip)
--------------------------------------------------------------------------------

local function buildChip()
	local gui = Instance.new("ScreenGui")
	gui.Name = "PetChip"
	gui.ResetOnSpawn = false
	gui.ScreenInsets = Enum.ScreenInsets.DeviceSafeInsets
	gui.DisplayOrder = CHIP_DISPLAY_ORDER
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling -- Global-default footgun

	local button = Instance.new("TextButton")
	button.Name = "Chip"
	button.AnchorPoint = Vector2.new(0, 0.5)
	button.Position = CHIP_POSITION
	button.Size = UDim2.fromOffset(CHIP_WIDTH_PX, CHIP_HEIGHT_PX)
	button.BackgroundColor3 = COLOR_PANEL
	button.BackgroundTransparency = 0.2
	button.BorderSizePixel = 0
	button.Text = ""
	button.AutoButtonColor = true
	button.Parent = gui
	makeRound(button, 12)

	local stroke = Instance.new("UIStroke")
	stroke.Color = COLOR_ACCENT
	stroke.Thickness = 1.5
	stroke.Transparency = 0.4
	stroke.Parent = button

	local caption = makeLabel("Caption", 11, true)
	caption.Position = UDim2.fromOffset(0, 6)
	caption.Size = UDim2.new(1, 0, 0, 12)
	caption.TextColor3 = COLOR_TEXT_DIM
	caption.Text = "PETS"
	caption.Parent = button

	local glyph = makeLabel("Glyph", 22, true)
	glyph.Position = UDim2.fromOffset(0, 18)
	glyph.Size = UDim2.new(1, 0, 0, 26)
	glyph.TextColor3 = COLOR_ACCENT
	glyph.Text = "=^.^="
	glyph.Parent = button

	local sub = makeLabel("Sub", 11, true)
	sub.Position = UDim2.new(0, 0, 1, -18)
	sub.Size = UDim2.new(1, 0, 0, 14)
	sub.TextColor3 = COLOR_TEXT_DIM
	sub.Text = "EQUIP"
	sub.Parent = button

	gui.Parent = LocalPlayer:WaitForChild("PlayerGui")

	button.Activated:Connect(function()
		PetUI.Toggle()
	end)
end

--------------------------------------------------------------------------------
-- Sheet construction (lazy: first Open builds it, §G join-time gate)
--------------------------------------------------------------------------------

local function buildGui()
	local gui = Instance.new("ScreenGui")
	gui.Name = "PetUI"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = false
	gui.ScreenInsets = Enum.ScreenInsets.DeviceSafeInsets
	gui.DisplayOrder = DISPLAY_ORDER
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling -- Global-default footgun

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

	local title = makeLabel("Title", 20, true)
	title.Position = UDim2.fromOffset(2, 12)
	title.Size = UDim2.new(1, -64, 0, 24)
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Text = "PETS"
	title.ZIndex = 3
	title.Parent = sheet

	local subtitle = makeLabel("Subtitle", 12, false)
	subtitle.Position = UDim2.fromOffset(2, 38)
	subtitle.Size = UDim2.new(1, -64, 0, 16)
	subtitle.TextXAlignment = Enum.TextXAlignment.Left
	subtitle.TextColor3 = COLOR_TEXT_DIM
	subtitle.Text = "One follower from your collection — perks scale with rarity."
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

	-- Upgrade row: TREAT level readout + the PET_TREATS quick-buy button.
	local upgradeRow = Instance.new("Frame")
	upgradeRow.Name = "UpgradeRow"
	upgradeRow.Position = UDim2.fromOffset(2, 60)
	upgradeRow.Size = UDim2.new(1, -4, 0, EQUIP_HEIGHT_PX + 8)
	upgradeRow.BackgroundColor3 = COLOR_PANEL_RAISED
	upgradeRow.BorderSizePixel = 0
	upgradeRow.ZIndex = 3
	upgradeRow.Parent = sheet
	makeRound(upgradeRow, 12)

	local levelLabel = makeLabel("LevelLabel", 13, true)
	levelLabel.Position = UDim2.fromOffset(ROW_PAD_PX, 0)
	levelLabel.Size = UDim2.new(1, -(ROW_PAD_PX * 3 + 150), 1, 0)
	levelLabel.TextXAlignment = Enum.TextXAlignment.Left
	levelLabel.TextColor3 = COLOR_TEXT
	levelLabel.Text = ""
	levelLabel.ZIndex = 3
	levelLabel.Parent = upgradeRow

	local upgradeButton = Instance.new("TextButton")
	upgradeButton.Name = "Upgrade"
	upgradeButton.AnchorPoint = Vector2.new(1, 0.5)
	upgradeButton.Position = UDim2.new(1, -6, 0.5, 0)
	upgradeButton.Size = UDim2.fromOffset(150, EQUIP_HEIGHT_PX)
	upgradeButton.BorderSizePixel = 0
	upgradeButton.Font = Enum.Font.GothamBold
	upgradeButton.TextSize = 14
	upgradeButton.Visible = false
	upgradeButton.ZIndex = 3
	upgradeButton.Parent = upgradeRow
	makeRound(upgradeButton, 10)

	local listTop = 60 + EQUIP_HEIGHT_PX + 8 + 8
	local list = Instance.new("ScrollingFrame")
	list.Name = "PetList"
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
	listLayout.Padding = UDim.new(0, ROW_GAP_PX)
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
		close = close,
		levelLabel = levelLabel,
		upgradeButton = upgradeButton,
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
		PetUI.Close()
	end)
	ui.scrim.Activated:Connect(function()
		PetUI.Close()
	end)
	ui.upgradeButton.Activated:Connect(function()
		local state = petState
		if state ~= nil and PetPerks.ClampLevel(state.upgradeLevel) >= GameConstants.PET_UPGRADE_MAX_LEVEL then
			return -- MAX badge: nothing to buy
		end
		invokeUpgradeWithPay()
	end)
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

function PetUI.IsOpen(): boolean
	return isOpen
end

function PetUI.Open()
	if isOpen then
		return
	end
	ensureGui()
	isOpen = true
	setCursorUnlocked(true) -- R4-2: cursor free while the sheet is up

	ui.scrim.Visible = true
	ui.sheet.Visible = true
	ui.sheet.Position = UDim2.fromScale(0.5, 1.25)
	TweenService:Create(
		ui.sheet,
		TweenInfo.new(SHEET_SLIDE_SECONDS, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
		{ Position = UDim2.fromScale(0.5, 1) }
	):Play()

	renderSheet() -- last state renders instantly...
	requestStateRefresh() -- ...while a fresh one is fetched

	-- R7 Fix #2: no pets yet -> short clock-in reminder toast. Strictly inside
	-- the empty guard so players with pets are never nagged.
	local state = petState
	if state ~= nil and #state.ownedIds == 0 then
		showClockInReminder()
	end
end

function PetUI.Close()
	if not isOpen then
		return
	end
	isOpen = false
	setCursorUnlocked(false) -- R4-2: first person re-locks next frame
	if ui ~= nil then
		ui.scrim.Visible = false
		ui.sheet.Visible = false
	end
end

function PetUI.Toggle()
	if isOpen then
		PetUI.Close()
	else
		PetUI.Open()
	end
end

--------------------------------------------------------------------------------
-- Server event handlers
--------------------------------------------------------------------------------

-- PET_TREATS grant landed (ShopUI owns the toast; we own the level readout).
local function onShopGrant(payload: any)
	if type(payload) == "table" and payload.sku == SKU_PET_TREATS then
		requestStateRefresh()
	end
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function PetUI:Init(registry: any)
	-- Nothing yielding here (loader contract); everything builds in Start/Open.
	registryRef = registry -- CursorUnlock lookup (R4-2)
end

function PetUI:Start()
	buildChip()
	Remotes.GetEvent("ShopGrant").OnClientEvent:Connect(onShopGrant)
end

return PetUI
