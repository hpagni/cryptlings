--!strict
-- CRYPTLINGS: NIGHT SHIFT — OddsUI (Stage 2, module unboxing-theater-ui).
-- The persistent "ODDS" pill + exact-odds sheet (SOP §8.1: pre-purchase odds
-- disclosure must match the in-hub odds board EXACTLY). The sheet renders the
-- server's GetOddsTable(tier) — the same single function that feeds the hub
-- board — so the numbers cannot diverge by construction. While the server
-- reply is in flight the sheet renders RarityTable.GetOdds(tier) locally
-- (identical module of record) and re-renders if the server says otherwise.
--
-- Public API (Controllers.Get("OddsUI")):
--   SetContext(source: string, tier: number?)  -- show the pill while any
--       context is active; tier defaults to the Tier-2 baseline. UnboxingUI
--       pushes "theater"; Stage 3 LockerUI pushes "locker".
--   ClearContext(source: string)               -- drop one context; pill hides
--       (and the sheet closes) when none remain.
--   Open(tier: number?) / Close() / IsOpen()
--
-- Mobile-first (§3.2/§G): pill and every tab/row >= 44px touch height,
-- bottom-sheet layout for one-thumb reach, viewport-driven UIScale.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RarityTable = require(Shared:WaitForChild("Config"):WaitForChild("RarityTable"))
local Remotes = require(Shared:WaitForChild("Net"):WaitForChild("Remotes"))

local LocalPlayer = Players.LocalPlayer

--------------------------------------------------------------------------------
-- Tuning (cosmetic, this module's domain)
--------------------------------------------------------------------------------

local DESIGN_SHORT_AXIS_PX = 450
local UISCALE_MIN = 0.85
local UISCALE_MAX = 1.6

local PILL_WIDTH_PX = 96
local PILL_HEIGHT_PX = 44 -- exactly the §G touch gate
local TAB_HEIGHT_PX = 44
local ROW_HEIGHT_PX = 34
local SHEET_WIDTH_PX = 340

local COLOR_PANEL = Color3.fromRGB(18, 20, 24)
local COLOR_PANEL_RAISED = Color3.fromRGB(30, 33, 40)
local COLOR_TEXT = Color3.fromRGB(235, 238, 240)
local COLOR_TEXT_DIM = Color3.fromRGB(160, 166, 172)
local COLOR_TAB_SELECTED = Color3.fromRGB(70, 120, 180)
local COLOR_FALLBACK = Color3.fromRGB(178, 178, 178)

local SERVER_FETCH_TIMEOUT_SECONDS = 5

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local OddsUI = {}

-- Active contexts, newest last; the pill shows while any are alive and the
-- default tier follows the most recent one.
local contexts: { { source: string, tier: number } } = {}

local sheetOpen = false
local selectedTier = RarityTable.BASELINE_TIER

-- Server odds cache per tier ({{rarity, pct}} arrays). Static for a session.
local serverOdds: { [number]: { { rarity: string, pct: number } } } = {}
local fetchInFlight: { [number]: boolean } = {}

local ui: any = nil

local registryRef: any = nil -- Controllers registry (CursorUnlock lookup)

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

-- R4-2: free the first-person cursor while the sheet is open. Safe registry
-- lookup, nil-guarded no-op until CursorUnlock registers; token = module name.
-- Every path that hides the sheet (close button, pill toggle, the refreshPill
-- auto-close when the last context clears) funnels through OddsUI.Close.
local function setCursorUnlocked(unlocked: boolean)
	if registryRef == nil or type(registryRef.Get) ~= "function" then
		return
	end
	local cursorUnlock = registryRef.Get("CursorUnlock")
	if cursorUnlock == nil then
		return
	end
	if unlocked then
		cursorUnlock.acquire("OddsUI")
	else
		cursorUnlock.release("OddsUI")
	end
end

local function rarityColor(rarity: string): Color3
	local color = (RarityTable.RARITY_COLORS :: any)[rarity]
	if typeof(color) == "Color3" then
		return color
	end
	return COLOR_FALLBACK
end

-- Exact percentage text: 65 -> "65%", 0.9 -> "0.9%", 0.001 -> "0.001%".
-- Weights are integers /1,000,000 (RarityTable.WEIGHT_TOTAL) so four decimals
-- always suffice; trailing zeros trimmed.
local function formatPct(pct: number): string
	if pct == math.floor(pct) then
		return string.format("%d%%", pct)
	end
	local text = string.format("%.4f", pct)
	text = string.gsub(text, "0+$", "")
	text = string.gsub(text, "%.$", "")
	return text .. "%"
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

local function validOddsArray(value: any): { { rarity: string, pct: number } }?
	if type(value) ~= "table" or #value == 0 then
		return nil
	end
	for _, row in value :: { any } do
		if type(row) ~= "table" or type(row.rarity) ~= "string" or type(row.pct) ~= "number" then
			return nil
		end
	end
	return value
end

--------------------------------------------------------------------------------
-- GUI construction (lazy)
--------------------------------------------------------------------------------

local function updateScale()
	if ui == nil then
		return
	end
	local camera = workspace.CurrentCamera
	if camera == nil then
		return
	end
	local shortAxis = math.min(camera.ViewportSize.X, camera.ViewportSize.Y)
	if shortAxis > 0 then
		ui.scale.Scale = math.clamp(shortAxis / DESIGN_SHORT_AXIS_PX, UISCALE_MIN, UISCALE_MAX)
	end
end

local renderSheet: () -> () -- forward (tab handlers and the fetch re-render)

local function buildGui()
	local gui = Instance.new("ScreenGui")
	gui.Name = "OddsUI"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = false
	gui.ScreenInsets = Enum.ScreenInsets.DeviceSafeInsets
	gui.DisplayOrder = 24 -- above the unboxing theater (20), below broadcasts (40)

	local root = Instance.new("Frame")
	root.Name = "Root"
	root.Size = UDim2.fromScale(1, 1)
	root.BackgroundTransparency = 1
	root.Parent = gui

	local scale = Instance.new("UIScale")
	scale.Parent = root

	-- The pill: top-left (theater's cancel X owns top-right).
	local pill = Instance.new("TextButton")
	pill.Name = "OddsPill"
	pill.Position = UDim2.fromOffset(10, 10)
	pill.Size = UDim2.fromOffset(PILL_WIDTH_PX, PILL_HEIGHT_PX)
	pill.BackgroundColor3 = COLOR_PANEL
	pill.BackgroundTransparency = 0.2
	pill.BorderSizePixel = 0
	pill.Font = Enum.Font.GothamBold
	pill.TextSize = 16
	pill.TextColor3 = COLOR_TEXT
	pill.Text = "ODDS"
	pill.Visible = false
	pill.Parent = root
	makeRound(pill, 22)
	local pillStroke = Instance.new("UIStroke")
	pillStroke.Color = COLOR_TEXT_DIM
	pillStroke.Thickness = 1
	pillStroke.Transparency = 0.4
	pillStroke.Parent = pill

	-- Bottom sheet.
	local sheet = Instance.new("Frame")
	sheet.Name = "Sheet"
	sheet.AnchorPoint = Vector2.new(0.5, 1)
	sheet.Position = UDim2.new(0.5, 0, 1, -8)
	sheet.Size = UDim2.fromOffset(SHEET_WIDTH_PX, 330)
	sheet.BackgroundColor3 = COLOR_PANEL
	sheet.BackgroundTransparency = 0.06
	sheet.BorderSizePixel = 0
	sheet.Visible = false
	sheet.Active = true -- taps on the sheet stay on the sheet
	sheet.Parent = root
	makeRound(sheet, 14)

	local title = makeLabel("Title", 17, true)
	title.Position = UDim2.fromOffset(16, 10)
	title.Size = UDim2.new(1, -76, 0, 24)
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Text = "CASE ODDS"
	title.Parent = sheet

	local closeButton = Instance.new("TextButton")
	closeButton.Name = "Close"
	closeButton.AnchorPoint = Vector2.new(1, 0)
	closeButton.Position = UDim2.new(1, -8, 0, 8)
	closeButton.Size = UDim2.fromOffset(44, 44)
	closeButton.BackgroundColor3 = COLOR_PANEL_RAISED
	closeButton.BorderSizePixel = 0
	closeButton.Font = Enum.Font.GothamBold
	closeButton.TextSize = 18
	closeButton.TextColor3 = COLOR_TEXT_DIM
	closeButton.Text = "X"
	closeButton.Parent = sheet
	makeRound(closeButton, 10)

	-- Tier tabs.
	local tabs = Instance.new("Frame")
	tabs.Name = "Tabs"
	tabs.Position = UDim2.fromOffset(12, 56)
	tabs.Size = UDim2.new(1, -24, 0, TAB_HEIGHT_PX)
	tabs.BackgroundTransparency = 1
	tabs.Parent = sheet
	local tabsLayout = Instance.new("UIListLayout")
	tabsLayout.FillDirection = Enum.FillDirection.Horizontal
	tabsLayout.Padding = UDim.new(0, 6)
	tabsLayout.SortOrder = Enum.SortOrder.LayoutOrder
	tabsLayout.Parent = tabs

	local tabButtons: { [number]: TextButton } = {}
	for tier = 1, 3 do
		local tab = Instance.new("TextButton")
		tab.Name = `Tier{tier}`
		tab.LayoutOrder = tier
		tab.Size = UDim2.fromOffset(101, TAB_HEIGHT_PX)
		tab.BackgroundColor3 = COLOR_PANEL_RAISED
		tab.BorderSizePixel = 0
		tab.Font = Enum.Font.GothamBold
		tab.TextSize = 14
		tab.TextColor3 = COLOR_TEXT
		tab.Text = `TIER {tier}`
		tab.Parent = tabs
		makeRound(tab, 10)
		tabButtons[tier] = tab
	end

	-- Rows.
	local rows = Instance.new("Frame")
	rows.Name = "Rows"
	rows.Position = UDim2.fromOffset(16, 108)
	rows.Size = UDim2.new(1, -32, 0, ROW_HEIGHT_PX * #RarityTable.RARITY_ORDER)
	rows.BackgroundTransparency = 1
	rows.Parent = sheet
	local rowsLayout = Instance.new("UIListLayout")
	rowsLayout.FillDirection = Enum.FillDirection.Vertical
	rowsLayout.SortOrder = Enum.SortOrder.LayoutOrder
	rowsLayout.Parent = rows

	-- Footer: the §8.1 promise, stated to the player.
	local footer = makeLabel("Footer", 11, false)
	footer.AnchorPoint = Vector2.new(0, 1)
	footer.Position = UDim2.new(0, 16, 1, -10)
	footer.Size = UDim2.new(1, -32, 0, 28)
	footer.TextColor3 = COLOR_TEXT_DIM
	footer.TextWrapped = true
	footer.Text =
		"Exact odds — the same numbers as the hub odds board. Tier 2 is the baseline on all purchased cases."
	footer.Parent = sheet

	ui = {
		gui = gui,
		root = root,
		scale = scale,
		pill = pill,
		sheet = sheet,
		title = title,
		tabButtons = tabButtons,
		rows = rows,
	}

	pill.Activated:Connect(function()
		if sheetOpen then
			OddsUI.Close()
		else
			OddsUI.Open()
		end
	end)
	closeButton.Activated:Connect(function()
		OddsUI.Close()
	end)
	for tier, tab in tabButtons do
		tab.Activated:Connect(function()
			selectedTier = tier
			renderSheet()
		end)
	end

	gui.Parent = LocalPlayer:WaitForChild("PlayerGui")
	updateScale()
	local camera = workspace.CurrentCamera
	if camera ~= nil then
		camera:GetPropertyChangedSignal("ViewportSize"):Connect(updateScale)
	end
end

local function ensureGui()
	if ui == nil then
		buildGui()
	end
end

--------------------------------------------------------------------------------
-- Odds data (server of record, local module as the in-flight stand-in)
--------------------------------------------------------------------------------

-- Kick off a one-time fetch of the server's odds for a tier; re-renders the
-- sheet when (and only when) the reply differs from what's already shown.
local function fetchServerOdds(tier: number)
	if serverOdds[tier] ~= nil or fetchInFlight[tier] then
		return
	end
	fetchInFlight[tier] = true
	task.spawn(function()
		local done = false
		task.spawn(function()
			local ok, result = pcall(function()
				return Remotes.GetFunction("GetOddsTable"):InvokeServer(tier)
			end)
			if ok then
				local rowsArray = validOddsArray(result)
				if rowsArray ~= nil then
					serverOdds[tier] = rowsArray
				end
			end
			done = true
		end)
		local deadline = os.clock() + SERVER_FETCH_TIMEOUT_SECONDS
		while not done and os.clock() < deadline do
			task.wait(0.1)
		end
		fetchInFlight[tier] = false
		if serverOdds[tier] ~= nil and sheetOpen and selectedTier == tier then
			renderSheet()
		end
	end)
end

local function oddsForTier(tier: number): { { rarity: string, pct: number } }
	local fromServer = serverOdds[tier]
	if fromServer ~= nil then
		return fromServer
	end
	-- Same module of record the server reads — identical numbers (§8.1).
	return RarityTable.GetOdds(tier)
end

--------------------------------------------------------------------------------
-- Rendering
--------------------------------------------------------------------------------

renderSheet = function()
	if ui == nil then
		return
	end

	ui.title.Text = `CASE ODDS — TIER {selectedTier}`
	for tier, tab in ui.tabButtons :: { [number]: TextButton } do
		tab.BackgroundColor3 = if tier == selectedTier then COLOR_TAB_SELECTED else COLOR_PANEL_RAISED
	end

	for _, child in ui.rows:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end

	for index, row in oddsForTier(selectedTier) do
		local rowFrame = Instance.new("Frame")
		rowFrame.Name = row.rarity
		rowFrame.LayoutOrder = index
		rowFrame.Size = UDim2.new(1, 0, 0, ROW_HEIGHT_PX)
		rowFrame.BackgroundTransparency = 1

		local dot = Instance.new("Frame")
		dot.Name = "Dot"
		dot.AnchorPoint = Vector2.new(0, 0.5)
		dot.Position = UDim2.fromScale(0, 0.5)
		dot.Size = UDim2.fromOffset(14, 14)
		dot.BackgroundColor3 = rarityColor(row.rarity)
		dot.BorderSizePixel = 0
		dot.Parent = rowFrame
		local dotCorner = Instance.new("UICorner")
		dotCorner.CornerRadius = UDim.new(1, 0)
		dotCorner.Parent = dot

		local nameLabel = makeLabel("Rarity", 15, true)
		nameLabel.Position = UDim2.fromOffset(24, 0)
		nameLabel.Size = UDim2.new(1, -110, 1, 0)
		nameLabel.TextXAlignment = Enum.TextXAlignment.Left
		nameLabel.TextColor3 = rarityColor(row.rarity)
		nameLabel.Text = row.rarity
		nameLabel.Parent = rowFrame

		local pctLabel = makeLabel("Pct", 15, true)
		pctLabel.AnchorPoint = Vector2.new(1, 0)
		pctLabel.Position = UDim2.fromScale(1, 0)
		pctLabel.Size = UDim2.fromOffset(86, ROW_HEIGHT_PX)
		pctLabel.TextXAlignment = Enum.TextXAlignment.Right
		pctLabel.Text = formatPct(row.pct)
		pctLabel.Parent = rowFrame

		rowFrame.Parent = ui.rows
	end

	fetchServerOdds(selectedTier)
end

local function refreshPill()
	if ui == nil then
		if #contexts > 0 then
			ensureGui()
		else
			return
		end
	end
	ui.pill.Visible = #contexts > 0
	if #contexts == 0 and sheetOpen then
		OddsUI.Close()
	end
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- Show the pill for a UI context ("theater", "locker", ...). Re-pushing the
-- same source just updates its tier. tier defaults to the Tier-2 baseline.
function OddsUI.SetContext(source: string, tier: number?)
	local resolvedTier = if type(tier) == "number"
			and tier >= 1
			and tier <= 3
		then math.floor(tier)
		else RarityTable.BASELINE_TIER
	for index = #contexts, 1, -1 do
		if contexts[index].source == source then
			table.remove(contexts, index)
		end
	end
	table.insert(contexts, { source = source, tier = resolvedTier })
	selectedTier = resolvedTier
	refreshPill()
	if sheetOpen then
		renderSheet()
	end
end

function OddsUI.ClearContext(source: string)
	for index = #contexts, 1, -1 do
		if contexts[index].source == source then
			table.remove(contexts, index)
		end
	end
	if #contexts > 0 then
		selectedTier = contexts[#contexts].tier
	end
	refreshPill()
end

function OddsUI.Open(tier: number?)
	ensureGui()
	if type(tier) == "number" and tier >= 1 and tier <= 3 then
		selectedTier = math.floor(tier)
	end
	sheetOpen = true
	setCursorUnlocked(true) -- R4-2: cursor free while the sheet is up
	renderSheet()
	local sheet = ui.sheet :: Frame
	sheet.Visible = true
	sheet.Position = UDim2.new(0.5, 0, 1, 80) -- slide up from below
	TweenService:Create(
		sheet,
		TweenInfo.new(0.22, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
		{ Position = UDim2.new(0.5, 0, 1, -8) }
	):Play()
end

function OddsUI.Close()
	sheetOpen = false
	setCursorUnlocked(false) -- R4-2: first person re-locks next frame
	if ui ~= nil then
		ui.sheet.Visible = false
	end
end

function OddsUI.IsOpen(): boolean
	return sheetOpen
end

-- Init only stores the registry (CursorUnlock lookup, R4-2); the gui still
-- builds lazily on the first SetContext/Open (§G join-time budget) and
-- everything else is event-driven. No Start needed.
function OddsUI:Init(registry: any)
	registryRef = registry
end

return OddsUI
