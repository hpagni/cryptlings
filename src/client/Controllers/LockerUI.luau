--!strict
-- CRYPTLINGS: NIGHT SHIFT — LockerUI (Stage 3, module locker-ui; R2 Addendum 1
-- Change 4: the physical locker bank is removed entirely).
-- The locker is the 24-48h return-habit engine (SOP §1.2): bank unlimited
-- sealed cases, open only 3 free per day (6 with VIP Locker), reset at the
-- 00:00 UTC unix-day boundary. This controller renders that state:
--   * Entry point: the persistent on-screen HUD locker chip ("LockerChip") —
--     the SOLE way in (Addendum 1 Change 4; no world geometry, no prompts).
--   * Bottom-sheet layout (one-thumb, §3.2): scrollable sealed-case grid of
--     tier-colored greybox case thumbnails in ViewportFrames. Random cases
--     SQUIRM (jitter bursts) with a faint giggle/cry whimper — the boxes
--     literally cry in the locker (§5.3 "your boxes are crying" hook).
--   * Opens-remaining pip row (opensPerDay pips + "+N EXTRA" credits chip)
--     and a live HH:MM:SS countdown to nextResetAt.
--   * Tap a case -> if any opens remain, hand off to UnboxingUI.PlayOpen
--     (registry call) and come back to the locker after the theater; at 0
--     opens, the blocked sheet: "Locker's sealed for tonight — back tomorrow"
--     + countdown. Post-Stage 6, a safe registry lookup of ShopUI adds an
--     "Extra opening — 49 R$" deep-link button (PriceLadder EXTRA_OPENING);
--     until ShopUI registers, the button simply does not exist.
--   * Sort: newest first (acquiredAt desc). Tier filter tabs ALL/T1/T2/T3.
--
-- Data flow: GetLockerState on open (guarded with a timeout so an unbound
-- remote can never hang the client) + live LockerChanged pushes; an
-- ExtractionResult triggers a refetch fallback so the grid reflects freshly
-- banked cases even if event ordering shifts. Fires FunnelClient
-- {event="ui_open_locker"} every open (§H whitelist).
--
-- Public API (Controllers.Get("LockerUI")):
--   LockerUI.Open()      -- opens the locker sheet (no-op while already open)
--   LockerUI.Close()
--   LockerUI.Toggle()
--   LockerUI.IsOpen() -> boolean

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
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

local SHOP_DEEP_LINK_SKU = "EXTRA_OPENING" -- PriceLadder row of record

-- Touch sizing: every interactive target >= the §G mobile gate.
local MIN_TOUCH_PX = GameConstants.MOBILE_MIN_TOUCH_TARGET_PX -- 44
local CLOSE_PX = math.max(MIN_TOUCH_PX, 48)
local TAB_HEIGHT_PX = math.max(MIN_TOUCH_PX, 46)
local BUTTON_HEIGHT_PX = math.max(MIN_TOUCH_PX, 52)
local CHIP_WIDTH_PX = 84
local CHIP_HEIGHT_PX = math.max(MIN_TOUCH_PX, 68)

-- Bottom sheet (one-thumb, §3.2): rises from the bottom edge, capped on
-- desktop so the grid never sprawls wider than a thumb-sweep.
local SHEET_HEIGHT_SCALE = 0.68
local SHEET_MAX_WIDTH_PX = 720
local SHEET_SLIDE_SECONDS = 0.18

-- Case grid.
local CARD_WIDTH_PX = 104
local CARD_HEIGHT_PX = 134
local CARD_VIEWPORT_HEIGHT_PX = 84
local GRID_PADDING_PX = 8

-- Squirm + cry (§5.3: the boxes cry in the locker).
local SQUIRM_CHANCE = 0.35 -- fraction of cards that squirm
local SQUIRM_BURST_SECONDS = 0.55
local SQUIRM_REST_MIN_SECONDS = 2.5
local SQUIRM_REST_MAX_SECONDS = 7.0
local SQUIRM_AMPLITUDE = 0.09 -- studs of viewport-model jitter
local CRY_MIN_INTERVAL_SECONDS = 2.8
local CRY_MAX_INTERVAL_SECONDS = 6.5
local CRY_VOLUME = 0.12 -- faint — heard, not blasted
local CRY_SOUND_ID = "rbxasset://sounds/impact_water.mp3" -- pitch-shifted squirm (uuhhh.mp3 reads as the death "oof")

local COUNTDOWN_TICK_SECONDS = 0.25
local STATE_FETCH_TIMEOUT_SECONDS = 6
local EXTRACTION_REFETCH_DELAY_SECONDS = 0.4

-- Palette (matches RunHUD/UnboxingUI greybox chrome).
local COLOR_PANEL = Color3.fromRGB(18, 20, 24)
local COLOR_PANEL_RAISED = Color3.fromRGB(30, 33, 39)
local COLOR_TEXT = Color3.fromRGB(235, 238, 240)
local COLOR_TEXT_DIM = Color3.fromRGB(160, 166, 172)
local COLOR_ACCENT = Color3.fromRGB(80, 220, 120) -- hub CLOCK-IN green (locker glow color)
local COLOR_GOLD = Color3.fromRGB(235, 190, 52)
local COLOR_PIP_EMPTY = Color3.fromRGB(60, 64, 70)
local COLOR_SCRIM = Color3.fromRGB(8, 9, 12)
local COLOR_TAPE = Color3.fromRGB(240, 234, 210)
local COLOR_BLOCKED = Color3.fromRGB(205, 60, 50)
local COLOR_FALLBACK = Color3.fromRGB(178, 178, 178)

-- Case tier -> greybox color, the same mapping RunHUD/UnboxingUI use
-- (T1 = Common grey, T2 = Rare blue baseline, T3 = Godly gold, §E palette).
local TIER_COLOR_KEYS: { [number]: string } =
	{ [1] = "Common", [2] = "Uncommon", [3] = "Rare", [4] = "Epic", [5] = "Legendary", [6] = "Mythical" }

-- DisplayOrder 16: above RunHUD (10), below the unboxing theater (20) so the
-- reveal always plays over the locker, below OddsUI (24) / BroadcastUI (40).
local DISPLAY_ORDER = 16

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local LockerUI = {}

local registryRef: any = nil
local unboxingUI: any = nil

local lockerState: Types.LockerState? = nil
local isOpen = false
local busyOpening = false -- a theater hand-off is in flight
local activeFilter: number? = nil -- nil = all tiers
local shiftStateName = "Intermission"
local lockedMidRun = false -- Active shift AND this player clocked in (mirrors ShopUI)
local sessionToken = 0 -- invalidates per-open loops on close
local refreshInFlight = false

local ui: any = nil -- bottom sheet refs (lazy)
local chip: any = nil -- HUD chip refs (built in Start)
local squirmConnection: RBXScriptConnection? = nil

type Squirmer = {
	parts: { BasePart },
	base: { CFrame },
	nextBurstAt: number,
	burstEndsAt: number,
	settled: boolean,
}
local squirmers: { Squirmer } = {}

--------------------------------------------------------------------------------
-- Small helpers
--------------------------------------------------------------------------------

local function tierColor(tier: number): Color3
	local key = TIER_COLOR_KEYS[tier]
	local color = if key ~= nil then (RarityTable.RARITY_COLORS :: any)[key] else nil
	if typeof(color) == "Color3" then
		return color
	end
	return COLOR_FALLBACK
end

-- R4-2: free the first-person cursor while the sheet is open. Safe registry
-- lookup, nil-guarded no-op until CursorUnlock registers; token = module name.
-- Every path that hides the sheet funnels through LockerUI.Close, which releases.
local function setCursorUnlocked(unlocked: boolean)
	if registryRef == nil or type(registryRef.Get) ~= "function" then
		return
	end
	local cursorUnlock = registryRef.Get("CursorUnlock")
	if cursorUnlock == nil then
		return
	end
	if unlocked then
		cursorUnlock.acquire("LockerUI")
	else
		cursorUnlock.release("LockerUI")
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

local function formatHMS(seconds: number): string
	local total = math.max(0, math.floor(seconds))
	return string.format("%02d:%02d:%02d", total // 3600, (total % 3600) // 60, total % 60)
end

local function relativeAge(acquiredAt: number): string
	local age = math.max(0, os.time() - acquiredAt)
	if age < 60 then
		return "just now"
	elseif age < 3600 then
		return `{age // 60}m ago`
	elseif age < 86400 then
		return `{age // 3600}h ago`
	end
	return `{age // 86400}d ago`
end

-- Extra-opening price from the ladder of record — never hardcoded (§4.2).
local function extraOpeningPriceText(): string
	local ok, row = pcall(function()
		return (PriceLadder :: any).GetRow(SHOP_DEEP_LINK_SKU)
	end)
	if ok and type(row) == "table" and type(row.priceRobux) == "number" then
		return `Extra opening — {row.priceRobux} R$`
	end
	return "Extra opening"
end

local function fireFunnel(event: string)
	task.spawn(function()
		local ok, remote = pcall(Remotes.GetEvent, "FunnelClient")
		if ok then
			(remote :: RemoteEvent):FireServer({ event = event })
		end
	end)
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

--------------------------------------------------------------------------------
-- Locker state fetch (guarded: an unbound/slow remote can never hang the UI)
--------------------------------------------------------------------------------

local function isLockerStateShaped(state: any): boolean
	return type(state) == "table"
		and type(state.cases) == "table"
		and type(state.freeOpensRemaining) == "number"
		and type(state.extraOpenCredits) == "number"
		and type(state.opensPerDay) == "number"
		and type(state.nextResetAt) == "number"
end

local function fetchLockerState(timeoutSeconds: number): Types.LockerState?
	local response: any = nil
	local done = false
	task.spawn(function()
		local ok, state = pcall(function()
			return Remotes.GetFunction("GetLockerState"):InvokeServer()
		end)
		if ok then
			response = state
		end
		done = true
	end)
	local deadline = os.clock() + timeoutSeconds
	while not done and os.clock() < deadline do
		task.wait(0.05)
	end
	if isLockerStateShaped(response) then
		return response :: Types.LockerState
	end
	return nil
end

local applyState: (Types.LockerState) -> () -- forward-declared (defined after the UI builders)

local function requestRefresh()
	if refreshInFlight then
		return
	end
	refreshInFlight = true
	task.spawn(function()
		local state = fetchLockerState(STATE_FETCH_TIMEOUT_SECONDS)
		refreshInFlight = false
		if state ~= nil then
			applyState(state)
		end
	end)
end

--------------------------------------------------------------------------------
-- HUD locker chip (left edge — clear of RunHUD's top cluster, the bottom-left
-- touch joystick and the bottom-center toasts)
--------------------------------------------------------------------------------

local function updateChip()
	if chip == nil then
		return
	end
	local state = lockerState
	if state == nil then
		chip.count.Text = "-"
		chip.opens.Text = "LOCKER"
	else
		chip.count.Text = tostring(#state.cases)
		local opensLeft = state.freeOpensRemaining + state.extraOpenCredits
		chip.opens.Text = if opensLeft > 0 then `{opensLeft} OPEN{if opensLeft == 1 then "" else "S"}` else "SEALED"
		chip.opens.TextColor3 = if opensLeft > 0 then COLOR_ACCENT else COLOR_TEXT_DIM
	end
	chip.button.Visible = not lockedMidRun
end

local function buildChip()
	local gui = Instance.new("ScreenGui")
	gui.Name = "LockerChip"
	gui.ResetOnSpawn = false
	gui.ScreenInsets = Enum.ScreenInsets.DeviceSafeInsets
	gui.DisplayOrder = DISPLAY_ORDER - 1 -- under the sheet's scrim

	local button = Instance.new("TextButton")
	button.Name = "Chip"
	button.AnchorPoint = Vector2.new(0, 0.5)
	button.Position = UDim2.new(0, 8, 0.56, 0)
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
	caption.Text = "LOCKER"
	caption.Parent = button

	local count = makeLabel("Count", 24, true)
	count.Position = UDim2.fromOffset(0, 18)
	count.Size = UDim2.new(1, 0, 0, 26)
	count.Text = "-"
	count.Parent = button

	local opens = makeLabel("Opens", 11, true)
	opens.Position = UDim2.new(0, 0, 1, -18)
	opens.Size = UDim2.new(1, 0, 0, 14)
	opens.TextColor3 = COLOR_ACCENT
	opens.Text = ""
	opens.Parent = button

	chip = { gui = gui, button = button, count = count, opens = opens }
	gui.Parent = LocalPlayer:WaitForChild("PlayerGui")

	button.Activated:Connect(function()
		LockerUI.Toggle()
	end)
	updateChip()
end

--------------------------------------------------------------------------------
-- Greybox case thumbnail (mini of the UnboxingUI theater case)
--------------------------------------------------------------------------------

local function makeCasePart(size: Vector3, cframe: CFrame, color: Color3): Part
	local part = Instance.new("Part")
	part.Size = size
	part.CFrame = cframe
	part.Color = color
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Material = Enum.Material.SmoothPlastic
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	return part
end

local function buildCaseThumbnail(viewport: ViewportFrame, tier: number): ({ BasePart }, { CFrame })
	local camera = Instance.new("Camera")
	camera.FieldOfView = 45
	camera.CFrame = CFrame.lookAt(Vector3.new(2.4, 3.2, -5.2), Vector3.new(0, 1.15, 0))
	camera.Parent = viewport
	viewport.CurrentCamera = camera

	local color = tierColor(tier)
	local parts: { BasePart } = {}
	local base: { CFrame } = {}
	local function add(part: BasePart)
		table.insert(parts, part)
		table.insert(base, part.CFrame)
		part.Parent = viewport
	end

	add(makeCasePart(Vector3.new(3, 2.1, 2.4), CFrame.new(0, 1.05, 0), color))
	add(makeCasePart(Vector3.new(3.2, 0.45, 2.6), CFrame.new(0, 2.35, 0), color:Lerp(Color3.new(0, 0, 0), 0.25)))
	local tape = makeCasePart(Vector3.new(3.3, 0.12, 0.7), CFrame.new(0, 2.62, 0), COLOR_TAPE)
	tape.Material = Enum.Material.Neon
	add(tape)
	return parts, base
end

--------------------------------------------------------------------------------
-- Bottom sheet construction (lazy: first Open builds it, §G join-time gate)
--------------------------------------------------------------------------------

local setFilter: (number?) -> () -- forward-declared

local function buildTab(parent: GuiObject, text: string, order: number): TextButton
	local tab = Instance.new("TextButton")
	tab.Name = `Tab{text}`
	tab.Size = UDim2.fromOffset(64, TAB_HEIGHT_PX)
	tab.BackgroundColor3 = COLOR_PANEL_RAISED
	tab.BorderSizePixel = 0
	tab.Font = Enum.Font.GothamBold
	tab.TextSize = 14
	tab.TextColor3 = COLOR_TEXT_DIM
	tab.Text = text
	tab.LayoutOrder = order
	tab.Parent = parent
	makeRound(tab, 10)
	return tab
end

local function buildGui()
	local gui = Instance.new("ScreenGui")
	gui.Name = "LockerUI"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = false
	gui.ScreenInsets = Enum.ScreenInsets.DeviceSafeInsets
	gui.DisplayOrder = DISPLAY_ORDER
	-- Sibling stacking: default-ZIndex children (filter tabs) must render above the ZIndex-2 sheet.
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	-- Scrim: tap anywhere above the sheet to close.
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

	-- The sheet itself.
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

	-- Grab notch (visual affordance that this is a sheet).
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

	-- Header: title + reset countdown, close X.
	local title = makeLabel("Title", 20, true)
	title.Position = UDim2.fromOffset(2, 12)
	title.Size = UDim2.new(1, -64, 0, 24)
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Text = "YOUR LOCKER"
	title.ZIndex = 3
	title.Parent = sheet

	local resetLabel = makeLabel("ResetCountdown", 13, false)
	resetLabel.Position = UDim2.fromOffset(2, 38)
	resetLabel.Size = UDim2.new(1, -64, 0, 16)
	resetLabel.TextXAlignment = Enum.TextXAlignment.Left
	resetLabel.TextColor3 = COLOR_TEXT_DIM
	resetLabel.Text = "Opens reset in --:--:--"
	resetLabel.ZIndex = 3
	resetLabel.Parent = sheet

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

	-- Pip row: opensPerDay pips + "+N EXTRA" credits chip.
	local pipRow = Instance.new("Frame")
	pipRow.Name = "PipRow"
	pipRow.Position = UDim2.fromOffset(2, 60)
	pipRow.Size = UDim2.new(1, -4, 0, 26)
	pipRow.BackgroundTransparency = 1
	pipRow.ZIndex = 3
	pipRow.Parent = sheet
	local pipLayout = Instance.new("UIListLayout")
	pipLayout.FillDirection = Enum.FillDirection.Horizontal
	pipLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	pipLayout.Padding = UDim.new(0, 6)
	pipLayout.SortOrder = Enum.SortOrder.LayoutOrder
	pipLayout.Parent = pipRow

	-- Tier filter tabs.
	local tabRow = Instance.new("Frame")
	tabRow.Name = "TabRow"
	tabRow.Position = UDim2.fromOffset(2, 92)
	tabRow.Size = UDim2.new(1, -4, 0, TAB_HEIGHT_PX)
	tabRow.BackgroundTransparency = 1
	tabRow.ZIndex = 3
	tabRow.Parent = sheet
	local tabLayout = Instance.new("UIListLayout")
	tabLayout.FillDirection = Enum.FillDirection.Horizontal
	tabLayout.Padding = UDim.new(0, 8)
	tabLayout.SortOrder = Enum.SortOrder.LayoutOrder
	tabLayout.Parent = tabRow

	local tabs: { [string]: TextButton } = {
		All = buildTab(tabRow, "ALL", 1),
		T1 = buildTab(tabRow, "T1", 2),
		T2 = buildTab(tabRow, "T2", 3),
		T3 = buildTab(tabRow, "T3", 4),
		T4 = buildTab(tabRow, "T4", 5),
		T5 = buildTab(tabRow, "T5", 6),
		T6 = buildTab(tabRow, "T6", 7),
	}

	-- The sealed-case grid.
	local grid = Instance.new("ScrollingFrame")
	grid.Name = "CaseGrid"
	grid.Position = UDim2.fromOffset(0, 92 + TAB_HEIGHT_PX + 8)
	grid.Size = UDim2.new(1, 0, 1, -(92 + TAB_HEIGHT_PX + 8))
	grid.BackgroundTransparency = 1
	grid.BorderSizePixel = 0
	grid.ScrollBarThickness = 6
	grid.ScrollBarImageColor3 = COLOR_PIP_EMPTY
	grid.ScrollingDirection = Enum.ScrollingDirection.Y
	grid.AutomaticCanvasSize = Enum.AutomaticSize.Y
	grid.CanvasSize = UDim2.new()
	grid.ZIndex = 3
	grid.Parent = sheet
	local gridLayout = Instance.new("UIGridLayout")
	gridLayout.CellSize = UDim2.fromOffset(CARD_WIDTH_PX, CARD_HEIGHT_PX)
	gridLayout.CellPadding = UDim2.fromOffset(GRID_PADDING_PX, GRID_PADDING_PX)
	gridLayout.SortOrder = Enum.SortOrder.LayoutOrder
	gridLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	gridLayout.Parent = grid

	local emptyLabel = makeLabel("EmptyState", 15, false)
	emptyLabel.AnchorPoint = Vector2.new(0.5, 0)
	emptyLabel.Position = UDim2.new(0.5, 0, 0, 36)
	emptyLabel.Size = UDim2.new(1, -40, 0, 60)
	emptyLabel.TextColor3 = COLOR_TEXT_DIM
	emptyLabel.TextWrapped = true
	emptyLabel.Visible = false
	emptyLabel.ZIndex = 3
	emptyLabel.Parent = grid
	emptyLabel.Text = ""

	-- Blocked sheet: full-gui overlay, above everything in this ScreenGui.
	local blocked = Instance.new("Frame")
	blocked.Name = "BlockedSheet"
	blocked.Size = UDim2.fromScale(1, 1)
	blocked.BackgroundColor3 = COLOR_SCRIM
	blocked.BackgroundTransparency = 0.3
	blocked.BorderSizePixel = 0
	blocked.Visible = false
	blocked.ZIndex = 10
	blocked.Parent = gui

	local blockedCard = Instance.new("Frame")
	blockedCard.Name = "Card"
	blockedCard.AnchorPoint = Vector2.new(0.5, 0.5)
	blockedCard.Position = UDim2.fromScale(0.5, 0.5)
	blockedCard.Size = UDim2.fromOffset(320, 232)
	blockedCard.BackgroundColor3 = COLOR_PANEL
	blockedCard.BorderSizePixel = 0
	blockedCard.ZIndex = 11
	blockedCard.Parent = blocked
	makeRound(blockedCard, 16)
	local blockedStroke = Instance.new("UIStroke")
	blockedStroke.Color = COLOR_BLOCKED
	blockedStroke.Thickness = 2
	blockedStroke.Transparency = 0.35
	blockedStroke.Parent = blockedCard

	local blockedTitle = makeLabel("Title", 18, true)
	blockedTitle.Position = UDim2.fromOffset(16, 18)
	blockedTitle.Size = UDim2.new(1, -32, 0, 52)
	blockedTitle.TextWrapped = true
	blockedTitle.Text = "Locker's sealed for tonight — back tomorrow"
	blockedTitle.ZIndex = 12
	blockedTitle.Parent = blockedCard

	local blockedCountdown = makeLabel("Countdown", 24, true)
	blockedCountdown.Position = UDim2.fromOffset(16, 78)
	blockedCountdown.Size = UDim2.new(1, -32, 0, 30)
	blockedCountdown.TextColor3 = COLOR_GOLD
	blockedCountdown.Text = "--:--:--"
	blockedCountdown.ZIndex = 12
	blockedCountdown.Parent = blockedCard

	local blockedSub = makeLabel("Sub", 12, false)
	blockedSub.Position = UDim2.fromOffset(16, 108)
	blockedSub.Size = UDim2.new(1, -32, 0, 16)
	blockedSub.TextColor3 = COLOR_TEXT_DIM
	blockedSub.Text = "until your free opens come back"
	blockedSub.ZIndex = 12
	blockedSub.Parent = blockedCard

	-- "Extra opening — 49 R$" deep link. Hidden unless ShopUI has registered
	-- (post-Stage 6); resolved fresh on every blocked-sheet show.
	local buyButton = Instance.new("TextButton")
	buyButton.Name = "BuyExtraOpen"
	buyButton.AnchorPoint = Vector2.new(0.5, 1)
	buyButton.Position = UDim2.new(0.5, 0, 1, -(BUTTON_HEIGHT_PX + 18))
	buyButton.Size = UDim2.new(1, -32, 0, BUTTON_HEIGHT_PX)
	buyButton.BackgroundColor3 = COLOR_GOLD
	buyButton.BorderSizePixel = 0
	buyButton.Font = Enum.Font.GothamBold
	buyButton.TextSize = 16
	buyButton.TextColor3 = COLOR_PANEL
	buyButton.Text = extraOpeningPriceText()
	buyButton.Visible = false
	buyButton.ZIndex = 12
	buyButton.Parent = blockedCard
	makeRound(buyButton, 12)

	local blockedClose = Instance.new("TextButton")
	blockedClose.Name = "Dismiss"
	blockedClose.AnchorPoint = Vector2.new(0.5, 1)
	blockedClose.Position = UDim2.new(0.5, 0, 1, -12)
	blockedClose.Size = UDim2.new(1, -32, 0, BUTTON_HEIGHT_PX)
	blockedClose.BackgroundColor3 = COLOR_PANEL_RAISED
	blockedClose.BorderSizePixel = 0
	blockedClose.Font = Enum.Font.GothamBold
	blockedClose.TextSize = 15
	blockedClose.TextColor3 = COLOR_TEXT
	blockedClose.Text = "OK"
	blockedClose.ZIndex = 12
	blockedClose.Parent = blockedCard
	makeRound(blockedClose, 12)

	-- Faint giggle/cry voice for the squirming boxes.
	local crySound = Instance.new("Sound")
	crySound.Name = "BoxCry"
	crySound.SoundId = CRY_SOUND_ID
	crySound.Volume = CRY_VOLUME
	crySound.Parent = gui

	ui = {
		gui = gui,
		scrim = scrim,
		sheet = sheet,
		title = title,
		resetLabel = resetLabel,
		close = close,
		pipRow = pipRow,
		tabRow = tabRow,
		tabs = tabs,
		grid = grid,
		gridLayout = gridLayout,
		emptyLabel = emptyLabel,
		blocked = blocked,
		blockedCard = blockedCard,
		blockedCountdown = blockedCountdown,
		buyButton = buyButton,
		blockedClose = blockedClose,
		crySound = crySound,
	}

	gui.Parent = LocalPlayer:WaitForChild("PlayerGui")
end

--------------------------------------------------------------------------------
-- Pip row
--------------------------------------------------------------------------------

local function rebuildPips()
	if ui == nil then
		return
	end
	for _, child in ui.pipRow:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end

	local state = lockerState
	local opensPerDay = if state ~= nil then state.opensPerDay else GameConstants.FREE_OPENS_PER_DAY
	local freeRemaining = if state ~= nil then state.freeOpensRemaining else 0
	local credits = if state ~= nil then state.extraOpenCredits else 0

	-- Plain text readout (pips don't scale to a 30-open allowance).
	local caption = makeLabel("Caption", 14, true)
	caption.Size = UDim2.fromOffset(260, 22)
	caption.TextXAlignment = Enum.TextXAlignment.Left
	caption.TextColor3 = if freeRemaining > 0 then COLOR_ACCENT else COLOR_TEXT_DIM
	caption.Text = `Opening Limit:  {freeRemaining} / {opensPerDay}`
	caption.LayoutOrder = 1
	caption.ZIndex = 3
	caption.Parent = ui.pipRow

	if credits > 0 then
		local creditsChip = makeLabel("Credits", 12, true)
		creditsChip.BackgroundTransparency = 0
		creditsChip.BackgroundColor3 = COLOR_GOLD
		creditsChip.TextColor3 = COLOR_PANEL
		creditsChip.Size = UDim2.fromOffset(76, 22)
		creditsChip.Text = `+{credits} EXTRA`
		creditsChip.LayoutOrder = 100
		creditsChip.ZIndex = 3
		creditsChip.Parent = ui.pipRow
		makeRound(creditsChip, 11)
	end
end

--------------------------------------------------------------------------------
-- Case grid
--------------------------------------------------------------------------------

local openCaseFlow: (Types.CaseStub) -> () -- forward-declared

local function isCaseStubShaped(stub: any): boolean
	return type(stub) == "table"
		and type(stub.uid) == "string"
		and type(stub.tier) == "number"
		and stub.tier >= 1
		and stub.tier <= 6
end

local function buildCaseCard(stub: Types.CaseStub, order: number)
	local card = Instance.new("TextButton")
	card.Name = `Case_{stub.uid}`
	card.BackgroundColor3 = COLOR_PANEL_RAISED
	card.BorderSizePixel = 0
	card.Text = ""
	card.AutoButtonColor = true
	card.LayoutOrder = order
	card.ZIndex = 3
	makeRound(card, 12)

	local stroke = Instance.new("UIStroke")
	stroke.Color = tierColor(stub.tier)
	stroke.Thickness = 1.5
	stroke.Transparency = 0.45
	stroke.Parent = card

	local viewport = Instance.new("ViewportFrame")
	viewport.Name = "Thumb"
	viewport.Position = UDim2.fromOffset(0, 4)
	viewport.Size = UDim2.new(1, 0, 0, CARD_VIEWPORT_HEIGHT_PX)
	viewport.BackgroundTransparency = 1
	viewport.Ambient = Color3.fromRGB(195, 195, 205)
	viewport.LightColor = Color3.fromRGB(255, 252, 244)
	viewport.LightDirection = Vector3.new(-0.4, -1, 0.6)
	viewport.ZIndex = 4
	viewport.Parent = card
	local parts, base = buildCaseThumbnail(viewport, stub.tier)

	local tierLabel = makeLabel("Tier", 14, true)
	tierLabel.Position = UDim2.new(0, 0, 1, -42)
	tierLabel.Size = UDim2.new(1, 0, 0, 18)
	tierLabel.TextColor3 = tierColor(stub.tier)
	tierLabel.Text = `TIER {stub.tier}`
	tierLabel.ZIndex = 4
	tierLabel.Parent = card

	local ageLabel = makeLabel("Age", 11, false)
	ageLabel.Position = UDim2.new(0, 0, 1, -22)
	ageLabel.Size = UDim2.new(1, 0, 0, 14)
	ageLabel.TextColor3 = COLOR_TEXT_DIM
	ageLabel.Text = relativeAge(stub.acquiredAt)
	ageLabel.ZIndex = 4
	ageLabel.Parent = card

	-- Some boxes squirm — they want out (§5.3).
	if math.random() < SQUIRM_CHANCE then
		table.insert(squirmers, {
			parts = parts,
			base = base,
			nextBurstAt = os.clock() + math.random() * SQUIRM_REST_MAX_SECONDS,
			burstEndsAt = 0,
			settled = true,
		})
	end

	card.Activated:Connect(function()
		openCaseFlow(stub)
	end)
	card.Parent = ui.grid
end

local function rebuildGrid()
	if ui == nil then
		return
	end
	table.clear(squirmers)
	for _, child in ui.grid:GetChildren() do
		if child:IsA("TextButton") then
			child:Destroy()
		end
	end

	local state = lockerState
	if state == nil then
		ui.emptyLabel.Text = "Checking your locker..."
		ui.emptyLabel.Visible = true
		return
	end

	-- Newest first (acquiredAt desc, uid tie-break), tier filter applied.
	local cases: { Types.CaseStub } = {}
	for _, stub in state.cases do
		if isCaseStubShaped(stub) and (activeFilter == nil or stub.tier == activeFilter) then
			table.insert(cases, stub)
		end
	end
	table.sort(cases, function(a, b)
		if a.acquiredAt ~= b.acquiredAt then
			return a.acquiredAt > b.acquiredAt
		end
		return a.uid > b.uid
	end)

	for order, stub in cases do
		buildCaseCard(stub, order)
	end

	if #cases == 0 then
		-- All tiers empty: the kid-friendly clock-in nudge. A tier filter hiding
		-- owned cases keeps its own short copy.
		ui.emptyLabel.Text = if activeFilter == nil
			then GameConstants.EMPTY_STATE.LOCKER_EMPTY
			else `No tier {activeFilter} boxes here.`
		ui.emptyLabel.Visible = true
	else
		ui.emptyLabel.Visible = false
	end
end

local function restyleTabs()
	if ui == nil then
		return
	end
	local selectedKey = if activeFilter == nil then "All" else `T{activeFilter}`
	for key, tab in ui.tabs :: { [string]: TextButton } do
		local selected = key == selectedKey
		tab.BackgroundColor3 = if selected then COLOR_ACCENT else COLOR_PANEL_RAISED
		tab.TextColor3 = if selected then COLOR_PANEL else COLOR_TEXT_DIM
	end
end

setFilter = function(tier: number?)
	activeFilter = tier
	restyleTabs()
	rebuildGrid()
end

--------------------------------------------------------------------------------
-- Countdown + state application
--------------------------------------------------------------------------------

local function updateCountdownLabels()
	if ui == nil then
		return
	end
	local state = lockerState
	local text = "--:--:--"
	if state ~= nil and state.nextResetAt > 0 then
		text = formatHMS(state.nextResetAt - os.time())
	end
	ui.resetLabel.Text = `Opens reset in {text}`
	ui.blockedCountdown.Text = text
end

applyState = function(state: Types.LockerState)
	lockerState = state
	updateChip()
	if ui ~= nil and isOpen then
		rebuildPips()
		rebuildGrid()
		updateCountdownLabels()
	end
end

local function onLockerChanged(payload: any)
	if isLockerStateShaped(payload) then
		applyState(payload :: Types.LockerState)
	end
end

--------------------------------------------------------------------------------
-- Squirm + cry loops (per open session)
--------------------------------------------------------------------------------

local function jitterTransform(amplitude: number): CFrame
	return CFrame.new((math.random() - 0.5) * amplitude * 2, (math.random() - 0.5) * amplitude, 0)
		* CFrame.Angles(0, (math.random() - 0.5) * amplitude * 2, (math.random() - 0.5) * amplitude)
end

local function stepSquirmers()
	local now = os.clock()
	for _, squirmer in squirmers do
		if now >= squirmer.nextBurstAt then
			squirmer.burstEndsAt = now + SQUIRM_BURST_SECONDS
			squirmer.nextBurstAt = now
				+ SQUIRM_REST_MIN_SECONDS
				+ math.random() * (SQUIRM_REST_MAX_SECONDS - SQUIRM_REST_MIN_SECONDS)
		end
		if now < squirmer.burstEndsAt then
			squirmer.settled = false
			local transform = jitterTransform(SQUIRM_AMPLITUDE)
			for index, part in squirmer.parts do
				part.CFrame = transform * squirmer.base[index]
			end
		elseif not squirmer.settled then
			squirmer.settled = true
			for index, part in squirmer.parts do
				part.CFrame = squirmer.base[index]
			end
		end
	end
end

-- Every few seconds a random squirmer whimpers: low pitch reads as a cry,
-- high pitch as a giggle. Forces that box into a squirm burst so sight and
-- sound line up.
local function startCryLoop(token: number)
	task.spawn(function()
		while isOpen and token == sessionToken do
			task.wait(CRY_MIN_INTERVAL_SECONDS + math.random() * (CRY_MAX_INTERVAL_SECONDS - CRY_MIN_INTERVAL_SECONDS))
			if not isOpen or token ~= sessionToken or ui == nil then
				break
			end
			if #squirmers > 0 then
				local squirmer = squirmers[math.random(1, #squirmers)]
				squirmer.nextBurstAt = 0 -- burst now
				ui.crySound.PlaybackSpeed = 0.85 + math.random() * 1.0
				ui.crySound.Volume = CRY_VOLUME
				ui.crySound:Play()
			end
		end
	end)
end

local function startCountdownLoop(token: number)
	task.spawn(function()
		local lastZeroRefetchAt = 0
		while isOpen and token == sessionToken do
			updateCountdownLabels()
			-- Reset boundary crossed while staring at the sheet: refetch so the
			-- pips refill live (UTC-day reset, §G).
			local state = lockerState
			if state ~= nil and state.nextResetAt > 0 and state.nextResetAt - os.time() <= 0 then
				if os.clock() - lastZeroRefetchAt > 5 then
					lastZeroRefetchAt = os.clock()
					requestRefresh()
				end
			end
			task.wait(COUNTDOWN_TICK_SECONDS)
		end
	end)
end

--------------------------------------------------------------------------------
-- Blocked sheet
--------------------------------------------------------------------------------

-- Safe registry lookup of ShopUI (ships Stage 6). Returns a deep-link thunk or
-- nil; the buy button only exists when the thunk does.
local function resolveShopDeepLink(): (() -> ())?
	if registryRef == nil or type(registryRef.Get) ~= "function" then
		return nil
	end
	local shop = registryRef.Get("ShopUI")
	if type(shop) ~= "table" then
		return nil
	end
	local opener = if type(shop.OpenTo) == "function" then shop.OpenTo else shop.Open
	if type(opener) ~= "function" then
		return nil
	end
	return function()
		local ok, err = pcall(opener, SHOP_DEEP_LINK_SKU)
		if not ok then
			warn(`[LockerUI] ShopUI deep link failed: {err}`)
		end
	end
end

local shopDeepLink: (() -> ())? = nil

local function showBlockedSheet()
	if ui == nil then
		return
	end
	shopDeepLink = resolveShopDeepLink()
	ui.buyButton.Text = extraOpeningPriceText()
	ui.buyButton.Visible = shopDeepLink ~= nil
	updateCountdownLabels()
	ui.blocked.Visible = true
end

local function hideBlockedSheet()
	if ui ~= nil then
		ui.blocked.Visible = false
	end
end

--------------------------------------------------------------------------------
-- Open / close / case tap flow
--------------------------------------------------------------------------------

local function ensureGui()
	if ui ~= nil then
		return
	end
	buildGui()
	ui.close.Activated:Connect(function()
		LockerUI.Close()
	end)
	ui.scrim.Activated:Connect(function()
		LockerUI.Close()
	end)
	ui.blockedClose.Activated:Connect(hideBlockedSheet)
	ui.buyButton.Activated:Connect(function()
		local deepLink = shopDeepLink
		if deepLink ~= nil then
			hideBlockedSheet()
			LockerUI.Close() -- hand the screen to the shop
			deepLink()
		end
	end)
	ui.tabs.All.Activated:Connect(function()
		setFilter(nil)
	end)
	for tier = 1, 6 do
		(ui.tabs[`T{tier}`] :: TextButton).Activated:Connect(function()
			setFilter(tier)
		end)
	end
	restyleTabs()
end

function LockerUI.IsOpen(): boolean
	return isOpen
end

function LockerUI.Open()
	if isOpen then
		return
	end
	-- The theater owns the screen mid-open; the sheet comes back right after.
	if unboxingUI ~= nil and type(unboxingUI.IsBusy) == "function" and unboxingUI.IsBusy() then
		return
	end
	ensureGui()
	isOpen = true
	setCursorUnlocked(true) -- R4-2: cursor free while the sheet is up
	sessionToken += 1
	local token = sessionToken

	hideBlockedSheet()
	ui.scrim.Visible = true
	ui.sheet.Visible = true
	ui.sheet.Position = UDim2.fromScale(0.5, 1.25)
	TweenService:Create(
		ui.sheet,
		TweenInfo.new(SHEET_SLIDE_SECONDS, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
		{ Position = UDim2.fromScale(0.5, 1) }
	):Play()

	fireFunnel("ui_open_locker")
	rebuildPips()
	rebuildGrid()
	updateCountdownLabels()

	squirmConnection = RunService.RenderStepped:Connect(stepSquirmers)
	startCountdownLoop(token)
	startCryLoop(token)
	requestRefresh()

	-- R7 Fix #2: empty locker + not clocked in -> short clock-in reminder toast.
	-- Strictly inside the empty guard so players with cases are never nagged.
	local state = lockerState
	if state ~= nil and #state.cases == 0 and not lockedMidRun then
		showClockInReminder()
	end
end

function LockerUI.Close()
	if not isOpen then
		return
	end
	isOpen = false
	setCursorUnlocked(false) -- R4-2: first person re-locks next frame
	sessionToken += 1
	if squirmConnection ~= nil then
		squirmConnection:Disconnect()
		squirmConnection = nil
	end
	if ui ~= nil then
		ui.scrim.Visible = false
		ui.sheet.Visible = false
		ui.blocked.Visible = false
		ui.crySound:Stop()
	end
end

function LockerUI.Toggle()
	if isOpen then
		LockerUI.Close()
	else
		LockerUI.Open()
	end
end

-- Optimistic local mirror of a successful open so the grid/pips react even
-- before LockerChanged lands; the server push remains authoritative.
local function applyOptimisticOpen(caseUid: string)
	local state = lockerState
	if state == nil then
		return
	end
	for index, stub in state.cases do
		if isCaseStubShaped(stub) and stub.uid == caseUid then
			table.remove(state.cases, index)
			break
		end
	end
	-- Free opens burn first, then extra-open credits (LockerService contract).
	if state.freeOpensRemaining > 0 then
		state.freeOpensRemaining -= 1
	elseif state.extraOpenCredits > 0 then
		state.extraOpenCredits -= 1
	end
	applyState(state)
end

openCaseFlow = function(stub: Types.CaseStub)
	if busyOpening or not isOpen then
		return
	end
	local state = lockerState
	local opensRemaining = if state ~= nil then state.freeOpensRemaining + state.extraOpenCredits else 0
	if opensRemaining <= 0 then
		showBlockedSheet()
		return
	end
	if unboxingUI == nil or type(unboxingUI.PlayOpen) ~= "function" then
		warn("[LockerUI] UnboxingUI is unavailable — cannot run the unboxing theater")
		return
	end

	busyOpening = true
	LockerUI.Close() -- the theater takes the whole screen
	task.spawn(function()
		local response: any = nil
		local ok, err = pcall(function()
			response = unboxingUI.PlayOpen(stub)
		end)
		if not ok then
			warn(`[LockerUI] PlayOpen failed: {err}`)
		end
		busyOpening = false

		if type(response) == "table" and response.ok == true then
			applyOptimisticOpen(stub.uid)
		end

		-- Back to the locker for the next case (or the bad news).
		LockerUI.Open()
		if type(response) == "table" and response.err == "NO_OPENS" then
			showBlockedSheet()
		end
		requestRefresh()
	end)
end

--------------------------------------------------------------------------------
-- Server event handlers
--------------------------------------------------------------------------------

local function onShiftState(payload: any)
	if type(payload) ~= "table" or type(payload.state) ~= "string" then
		return
	end
	shiftStateName = payload.state
	-- Only a clocked-in (not yet extracted) runner loses the locker chip; hub
	-- bystanders keep it through shifts they're not part of, and an extracted
	-- player gets it back instantly (server sends participant=false on extract).
	lockedMidRun = shiftStateName == "Active" and payload.participant == true
	if lockedMidRun then
		LockerUI.Close() -- no locker browsing mid-run
	end
	updateChip()
end

local function onExtractionResult(payload: any)
	-- Freshly banked cases land in the locker server-side; refetch shortly so
	-- the grid reflects them even if the LockerChanged push raced this event.
	if type(payload) == "table" and payload.extracted == true then
		task.delay(EXTRACTION_REFETCH_DELAY_SECONDS, requestRefresh)
	end
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function LockerUI:Init(registry: any)
	registryRef = registry
	-- No world discovery: the locker has no physical surface (Addendum 1
	-- Change 4) — the on-screen chip built in Start is the sole entry point.
end

function LockerUI:Start()
	if registryRef ~= nil and type(registryRef.Get) == "function" then
		unboxingUI = registryRef.Get("UnboxingUI")
	end

	buildChip()

	Remotes.GetEvent("LockerChanged").OnClientEvent:Connect(onLockerChanged)
	Remotes.GetEvent("ShiftState").OnClientEvent:Connect(onShiftState)
	Remotes.GetEvent("ExtractionResult").OnClientEvent:Connect(onExtractionResult)

	-- Seed the chip. LockerService binds the GetLockerState handler at server
	-- boot; if it is ever absent (mid-construction build) the guarded fetch
	-- just times out and the chip stays in its placeholder state.
	requestRefresh()
end

return LockerUI
