--!strict
-- CRYPTLINGS: NIGHT SHIFT — BrainrotWallUI (lobby rebuild WP3.6; LOBBY_SOP §7,
-- §12-10; header per R2 Addendum 1 Change 7). The Current Factory Brainrots
-- wall: the idle-time read facing the queue pad, so the 45 s wait doubles as
-- browsing time.
--
-- WallBuilder ships only the bare slab (tagged "BrainrotWall"); this controller
-- renders the entire card grid CLIENT-SIDE as a SurfaceGui that lives in
-- PlayerGui with its Adornee set via code (StreamingEnabled-safe: re-adorns
-- whenever the slab streams back in, exactly like CountdownUI's wall).
--
--   * HEADER — "CURRENT FACTORY BRAINROTS" (Addendum 1 Change 7: house
--     all-caps of the exact required words) + a rotation
--     countdown "Rotates in Xd Xh Xm" read from CountdownUI.GetCountdowns()
--     .nightlyRotationAt and ticked locally per RenderStepped second — NO
--     per-second remotes (§7).
--   * CARD GRID — one card per Cryptling in the RarityTable rotation pools,
--     ordered rarest -> most common (the rare bait reads first): ViewportFrame
--     of the recipe slowly rotating (UI-only, allowed by the §10 no-world-
--     viewport rule), name, rarity pill + card border in RARITY_COLORS (the
--     wall reads as a color histogram from the street), odds line from the
--     baseline-tier RarityTable.GetOdds with the rarest tier masked "???"
--     (PS99-style). If the roster ever exceeds BRAINROT_WALL.MAX_VIEWPORT_CARDS
--     the viewports drop to flat color swatches (§7 perf rule).
--   * OWNED STATE — Cryptlings the local player already owns (Pet.GetState
--     ownedIds) are dimmed + checkmarked: the wall becomes a collection
--     checklist. Refreshed on the local player's ShelfChanged and every time
--     the wall (re)adorns.
--
-- ONE RenderStepped connection drives both the countdown tick and the viewport
-- spin; spin pauses entirely when the camera is beyond the display animate
-- radius (same 120-stud cull discipline as the podium displays).
--
-- No public API beyond the loader lifecycle; pure-client, grants nothing
-- (Security Review Scope §6).

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local LobbyConfig = require(Shared:WaitForChild("Config"):WaitForChild("LobbyConfig"))
local RarityTable = require(Shared:WaitForChild("Config"):WaitForChild("RarityTable"))
local Remotes = require(Shared:WaitForChild("Net"):WaitForChild("Remotes"))

local LocalPlayer = Players.LocalPlayer

--------------------------------------------------------------------------------
-- Tuning (cosmetic, this module's domain — SOP numbers stay in LobbyConfig)
--------------------------------------------------------------------------------

local TAG_WALL = "BrainrotWall" -- WallBuilder tags the slab (contract of record)
local HEADER_TEXT = "CURRENT FACTORY BRAINROTS" -- Addendum 1 Change 7 (house all-caps of the exact words)

local PIXELS_PER_STUD = 40 -- 48x14 slab -> 1920x560 canvas
local HEADER_HEIGHT_PX = 64
local GRID_PADDING_PX = 8
local GRID_COLUMNS = 8
local CARD_WIDTH_PX = 230
local CARD_HEIGHT_PX = 150
local VIEWPORT_HEIGHT_PX = 76

local CARD_FETCH_TIMEOUT_SECONDS = 5 -- guarded Pet.GetState fetch (never hangs)

local COLOR_PANEL = Color3.fromRGB(18, 20, 24)
local COLOR_CARD = Color3.fromRGB(24, 26, 32)
local COLOR_TEXT = Color3.fromRGB(232, 230, 224)
local COLOR_TEXT_DIM = Color3.fromRGB(160, 166, 172)
local COLOR_OWNED_CHECK = Color3.fromRGB(120, 230, 140)
local OWNED_DIM_TRANSPARENCY = 0.55 -- dark overlay over owned cards (checklist read)

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local BrainrotWallUI = {}

type CardRefs = {
	ownedOverlay: Frame,
	ownedCheck: TextLabel,
}

type Spinner = {
	camera: Camera,
	focus: Vector3,
	distance: number,
	height: number,
	phase: number,
}

local registryRef: any = nil

local wallPart: BasePart? = nil
local wallGui: SurfaceGui? = nil
local countdownLabel: TextLabel? = nil

local cardRefsById: { [string]: CardRefs } = {}
local spinners: { Spinner } = {}

local ownedSet: { [string]: boolean } = {}
local ownedFetchInFlight = false

local lastCountdownSecond = -1

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

-- Server-synchronized unix time (same epoch as nightlyRotationAt — see
-- CountdownUI/RotationService).
local function serverNow(): number
	return Workspace:GetServerTimeNow()
end

local function rgbToColor3(c: { R: number, G: number, B: number }): Color3
	return Color3.fromRGB(c.R, c.G, c.B)
end

local function rarityColor(rarity: string): Color3
	local color = (RarityTable.RARITY_COLORS :: any)[rarity]
	if typeof(color) == "Color3" then
		return color
	end
	return COLOR_TEXT_DIM
end

local function rarityDisplay(rarity: string): string
	local display = (RarityTable.RARITY_DISPLAY :: any)[rarity]
	if type(display) == "string" then
		return display
	end
	return rarity
end

-- "Rotates in Xd XXh XXm" (SOP §7 header countdown format).
local function formatRotation(secondsLeft: number): string
	local s = math.max(0, math.floor(secondsLeft))
	local days = s // 86400
	local hours = (s % 86400) // 3600
	local minutes = (s % 3600) // 60
	return string.format("Rotates in %dd %02dh %02dm", days, hours, minutes)
end

-- Exact disclosed percentage, trailing zeros trimmed ("49.949%", "0.05%", "30%").
local function formatPct(pct: number): string
	local text = string.format("%.3f", pct)
	text = string.gsub(text, "0+$", "")
	text = string.gsub(text, "%.$", "")
	return `{text}%`
end

-- Rotation roster, rarest -> most common (rare end reads first from the pad —
-- the §7 bait ordering; the grid fills top-left first on the pad-facing gui).
local function collectRosterRarestFirst(): { any }
	local defs: { any } = {}
	for index = #RarityTable.RARITY_ORDER, 1, -1 do
		local rarity = RarityTable.RARITY_ORDER[index]
		for _, def in RarityTable.GetPoolByRarity(rarity) do
			table.insert(defs, def)
		end
	end
	return defs
end

-- Baseline-tier disclosed odds line per rarity; the rarest tier masks as "???"
-- (PS99-style mystery chase — §7).
local function buildOddsTextByRarity(): { [string]: string }
	local rarestRarity = RarityTable.RARITY_ORDER[#RarityTable.RARITY_ORDER]
	local oddsText: { [string]: string } = {}
	for _, entry in RarityTable.GetOdds(RarityTable.BASELINE_TIER) do
		if entry.rarity == rarestRarity then
			oddsText[entry.rarity] = "???"
		else
			oddsText[entry.rarity] = formatPct(entry.pct)
		end
	end
	return oddsText
end

--------------------------------------------------------------------------------
-- Recipe -> slowly-rotating viewport (greybox render spec of record, §E)
--------------------------------------------------------------------------------

local function makeGreyboxPart(shape: string, size: Vector3, cframe: CFrame, color: Color3): BasePart
	local part: BasePart
	if shape == "Wedge" then
		part = Instance.new("WedgePart")
	else
		local p = Instance.new("Part")
		if shape == "Ball" then
			p.Shape = Enum.PartType.Ball
		elseif shape == "Cylinder" then
			p.Shape = Enum.PartType.Cylinder
		end
		part = p
	end
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

-- Fills a ViewportFrame with the cryptling's recipe and registers its camera
-- in the shared spin list (ONE RenderStepped loop orbits them all).
local function buildViewport(viewport: ViewportFrame, def: any, phase: number)
	local baseColor = if typeof(def.color) == "Color3" then def.color :: Color3 else COLOR_TEXT_DIM

	local maxY = 1.5
	local maxRadius = 1.2
	if type(def.recipe) == "table" then
		for _, rp in def.recipe :: { any } do
			if typeof(rp.size) ~= "Vector3" or typeof(rp.offset) ~= "CFrame" then
				continue
			end
			local size = rp.size :: Vector3
			local offset = rp.offset :: CFrame
			local color = if typeof(rp.colorOverride) == "Color3" then rp.colorOverride :: Color3 else baseColor
			makeGreyboxPart(rp.shape, size, offset, color).Parent = viewport
			maxY = math.max(maxY, offset.Position.Y + size.Y / 2)
			local horizontal = math.max(size.X, size.Z) / 2
			maxRadius =
				math.max(maxRadius, math.abs(offset.Position.X) + horizontal, math.abs(offset.Position.Z) + horizontal)
		end
	else
		makeGreyboxPart("Ball", Vector3.new(2, 2, 2), CFrame.new(0, 1, 0), baseColor).Parent = viewport
	end

	local focus = Vector3.new(0, maxY / 2, 0)
	local distance = math.max(maxRadius, maxY / 2) * 2.7 + 1.4
	local height = maxY * 0.35 + 0.6
	local camera = Instance.new("Camera")
	camera.FieldOfView = 40
	camera.CFrame =
		CFrame.lookAt(focus + Vector3.new(math.cos(phase) * distance, height, math.sin(phase) * distance), focus)
	camera.Parent = viewport
	viewport.CurrentCamera = camera

	table.insert(spinners, {
		camera = camera,
		focus = focus,
		distance = distance,
		height = height,
		phase = phase,
	})
end

--------------------------------------------------------------------------------
-- Card grid
--------------------------------------------------------------------------------

local function buildCard(parent: Instance, def: any, layoutOrder: number, oddsText: string, useViewport: boolean)
	local tint = rarityColor(def.rarity)

	local card = Instance.new("Frame")
	card.Name = `Card_{def.id}`
	card.LayoutOrder = layoutOrder
	card.BackgroundColor3 = COLOR_CARD
	card.BackgroundTransparency = 0.1
	card.BorderSizePixel = 0
	local cardCorner = Instance.new("UICorner")
	cardCorner.CornerRadius = UDim.new(0, 8)
	cardCorner.Parent = card
	-- Card border tinted to the rarity (the color-histogram read, §7).
	local cardStroke = Instance.new("UIStroke")
	cardStroke.Thickness = 2
	cardStroke.Color = tint
	cardStroke.Parent = card

	if useViewport then
		local viewport = Instance.new("ViewportFrame")
		viewport.Name = "Thumb"
		viewport.BackgroundColor3 = COLOR_PANEL
		viewport.BackgroundTransparency = 0.25
		viewport.Position = UDim2.fromOffset(6, 6)
		viewport.Size = UDim2.new(1, -12, 0, VIEWPORT_HEIGHT_PX)
		viewport.Ambient = Color3.fromRGB(140, 140, 140)
		viewport.LightColor = Color3.fromRGB(255, 250, 240)
		viewport.LightDirection = Vector3.new(-0.4, -1, -0.6)
		viewport.Parent = card
		local viewportCorner = Instance.new("UICorner")
		viewportCorner.CornerRadius = UDim.new(0, 6)
		viewportCorner.Parent = viewport
		buildViewport(viewport, def, layoutOrder * 0.7)
	else
		-- Perf fallback past MAX_VIEWPORT_CARDS: flat rarity swatch (§7).
		local swatch = Instance.new("Frame")
		swatch.Name = "Swatch"
		swatch.BackgroundColor3 = if typeof(def.color) == "Color3" then def.color :: Color3 else tint
		swatch.BackgroundTransparency = 0.2
		swatch.BorderSizePixel = 0
		swatch.Position = UDim2.fromOffset(6, 6)
		swatch.Size = UDim2.new(1, -12, 0, VIEWPORT_HEIGHT_PX)
		swatch.Parent = card
		local swatchCorner = Instance.new("UICorner")
		swatchCorner.CornerRadius = UDim.new(0, 6)
		swatchCorner.Parent = swatch
	end

	local nameLabel = Instance.new("TextLabel")
	nameLabel.Name = "PetName"
	nameLabel.BackgroundTransparency = 1
	nameLabel.Position = UDim2.fromOffset(6, 84)
	nameLabel.Size = UDim2.new(1, -12, 0, 22)
	nameLabel.Font = Enum.Font.GothamBold
	nameLabel.TextSize = 17
	nameLabel.TextColor3 = COLOR_TEXT
	nameLabel.TextTruncate = Enum.TextTruncate.AtEnd
	nameLabel.Text = if type(def.name) == "string" then def.name else def.id
	nameLabel.Parent = card

	local pill = Instance.new("Frame")
	pill.Name = "RarityPill"
	pill.BackgroundColor3 = tint
	pill.BackgroundTransparency = 0.15
	pill.BorderSizePixel = 0
	pill.Position = UDim2.fromOffset(6, 108)
	pill.Size = UDim2.new(1, -12, 0, 18)
	pill.Parent = card
	local pillCorner = Instance.new("UICorner")
	pillCorner.CornerRadius = UDim.new(1, 0)
	pillCorner.Parent = pill

	local pillLabel = Instance.new("TextLabel")
	pillLabel.Name = "RarityName"
	pillLabel.BackgroundTransparency = 1
	pillLabel.Size = UDim2.fromScale(1, 1)
	pillLabel.Font = Enum.Font.GothamBold
	pillLabel.TextSize = 12
	pillLabel.TextColor3 = COLOR_PANEL
	pillLabel.Text = rarityDisplay(def.rarity)
	pillLabel.Parent = pill

	local oddsLabel = Instance.new("TextLabel")
	oddsLabel.Name = "Odds"
	oddsLabel.BackgroundTransparency = 1
	oddsLabel.Position = UDim2.fromOffset(6, 128)
	oddsLabel.Size = UDim2.new(1, -12, 0, 16)
	oddsLabel.Font = Enum.Font.Gotham
	oddsLabel.TextSize = 13
	oddsLabel.TextColor3 = COLOR_TEXT_DIM
	oddsLabel.Text = oddsText
	oddsLabel.Parent = card

	-- Owned state: dim overlay + checkmark (collection-checklist read, §7).
	local overlay = Instance.new("Frame")
	overlay.Name = "OwnedDim"
	overlay.BackgroundColor3 = Color3.new(0, 0, 0)
	overlay.BackgroundTransparency = OWNED_DIM_TRANSPARENCY
	overlay.BorderSizePixel = 0
	overlay.Size = UDim2.fromScale(1, 1)
	overlay.ZIndex = 3
	overlay.Visible = false
	overlay.Parent = card
	local overlayCorner = Instance.new("UICorner")
	overlayCorner.CornerRadius = UDim.new(0, 8)
	overlayCorner.Parent = overlay

	local check = Instance.new("TextLabel")
	check.Name = "OwnedCheck"
	check.BackgroundTransparency = 1
	check.AnchorPoint = Vector2.new(1, 0)
	check.Position = UDim2.new(1, -6, 0, 4)
	check.Size = UDim2.fromOffset(24, 24)
	check.Font = Enum.Font.GothamBlack
	check.TextSize = 22
	check.TextColor3 = COLOR_OWNED_CHECK
	check.Text = "✓"
	check.ZIndex = 4
	check.Visible = false
	check.Parent = card

	cardRefsById[def.id] = { ownedOverlay = overlay, ownedCheck = check }
	card.Parent = parent
end

local function buildWallGui(): SurfaceGui
	local gui = Instance.new("SurfaceGui")
	gui.Name = "BrainrotWallGui"
	gui.ResetOnSpawn = false
	gui.Face = Enum.NormalId.Front -- WallBuilder mounts the slab front toward the pad
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = PIXELS_PER_STUD
	gui.ClipsDescendants = true
	gui.LightInfluence = 0 -- per-cell LightInfluence 0 (§7/§11.1 night-sign rule)
	gui.Brightness = LobbyConfig.SURFACE_GUI.BRIGHTNESS
	gui.Enabled = false -- until the slab is found

	local background = Instance.new("Frame")
	background.Name = "Background"
	background.Size = UDim2.fromScale(1, 1)
	background.BackgroundColor3 = COLOR_PANEL
	background.BackgroundTransparency = 0.2
	background.BorderSizePixel = 0
	background.Parent = gui

	-- Header strip: verbatim title + locally-ticked rotation countdown.
	local headerLabel = Instance.new("TextLabel")
	headerLabel.Name = "Header"
	headerLabel.BackgroundTransparency = 1
	headerLabel.Position = UDim2.fromOffset(GRID_PADDING_PX, 0)
	headerLabel.Size = UDim2.new(0.66, -GRID_PADDING_PX, 0, HEADER_HEIGHT_PX)
	headerLabel.Font = Enum.Font.GothamBlack
	headerLabel.TextScaled = true
	headerLabel.TextXAlignment = Enum.TextXAlignment.Left
	headerLabel.TextColor3 = rgbToColor3(LobbyConfig.SIGN_TEXT_COLOR)
	headerLabel.Text = HEADER_TEXT
	headerLabel.Parent = background

	local rotateLabel = Instance.new("TextLabel")
	rotateLabel.Name = "RotatesIn"
	rotateLabel.BackgroundTransparency = 1
	rotateLabel.AnchorPoint = Vector2.new(1, 0)
	rotateLabel.Position = UDim2.new(1, -GRID_PADDING_PX, 0, 0)
	rotateLabel.Size = UDim2.new(0.32, 0, 0, HEADER_HEIGHT_PX)
	rotateLabel.Font = Enum.Font.GothamBold
	rotateLabel.TextSize = 30
	rotateLabel.TextXAlignment = Enum.TextXAlignment.Right
	rotateLabel.TextColor3 = COLOR_TEXT_DIM
	rotateLabel.Text = "Rotates in --d --h --m"
	rotateLabel.Parent = background
	countdownLabel = rotateLabel

	-- Card grid: rarest -> common in LayoutOrder (top row = chase tiers).
	local grid = Instance.new("ScrollingFrame")
	grid.Name = "Cards"
	grid.BackgroundTransparency = 1
	grid.BorderSizePixel = 0
	grid.Position = UDim2.fromOffset(GRID_PADDING_PX, HEADER_HEIGHT_PX)
	grid.Size = UDim2.new(1, -GRID_PADDING_PX * 2, 1, -(HEADER_HEIGHT_PX + GRID_PADDING_PX))
	grid.CanvasSize = UDim2.fromScale(0, 0)
	grid.AutomaticCanvasSize = Enum.AutomaticSize.Y
	grid.ScrollBarThickness = 0
	grid.ScrollingEnabled = false -- wall display, not an interactive surface
	grid.Parent = background

	local layout = Instance.new("UIGridLayout")
	layout.CellSize = UDim2.fromOffset(CARD_WIDTH_PX, CARD_HEIGHT_PX)
	layout.CellPadding = UDim2.fromOffset(GRID_PADDING_PX, GRID_PADDING_PX)
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.FillDirectionMaxCells = GRID_COLUMNS
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = grid

	local roster = collectRosterRarestFirst()
	local oddsTextByRarity = buildOddsTextByRarity()
	local useViewports = #roster <= LobbyConfig.BRAINROT_WALL.MAX_VIEWPORT_CARDS
	for index, def in roster do
		buildCard(grid, def, index, oddsTextByRarity[def.rarity] or "???", useViewports)
	end

	return gui
end

--------------------------------------------------------------------------------
-- Owned-state refresh (Pet.GetState ownedIds; pure display, grants nothing)
--------------------------------------------------------------------------------

local function applyOwnedState()
	for id, refs in cardRefsById do
		local owned = ownedSet[id] == true
		refs.ownedOverlay.Visible = owned
		refs.ownedCheck.Visible = owned
	end
end

local function refreshOwned()
	if ownedFetchInFlight then
		return
	end
	ownedFetchInFlight = true
	task.spawn(function()
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
		local deadline = os.clock() + CARD_FETCH_TIMEOUT_SECONDS
		while not done and os.clock() < deadline do
			task.wait(0.05)
		end
		ownedFetchInFlight = false
		if type(response) ~= "table" or type(response.ownedIds) ~= "table" then
			return -- unanswered/misshapen: keep the last known owned set
		end
		local fresh: { [string]: boolean } = {}
		for _, id in response.ownedIds :: { any } do
			if type(id) == "string" then
				fresh[id] = true
			end
		end
		ownedSet = fresh
		applyOwnedState()
	end)
end

--------------------------------------------------------------------------------
-- Slab resolution (streaming-safe re-adorn, tag contract of record)
--------------------------------------------------------------------------------

local function findWallSlab(): BasePart?
	for _, instance in CollectionService:GetTagged(TAG_WALL) do
		if instance:IsA("BasePart") and instance:IsDescendantOf(Workspace) then
			return instance
		end
	end
	return nil
end

local function ensureWallAdornee()
	local current = wallPart
	if current ~= nil and current:IsDescendantOf(Workspace) then
		return
	end
	wallPart = nil

	local gui = wallGui
	if gui == nil then
		return
	end
	local slab = findWallSlab()
	if slab ~= nil then
		wallPart = slab
		gui.Adornee = slab
		gui.Enabled = true
		refreshOwned() -- the wall just came into view: re-sync the checklist
	else
		gui.Adornee = nil
		gui.Enabled = false
	end
end

--------------------------------------------------------------------------------
-- Render tick (ONE RenderStepped connection: countdown second + viewport spin)
--------------------------------------------------------------------------------

local function readNightlyRotationAt(): number?
	if registryRef == nil or type(registryRef.Get) ~= "function" then
		return nil
	end
	local countdownUI = registryRef.Get("CountdownUI")
	if countdownUI == nil or type(countdownUI.GetCountdowns) ~= "function" then
		return nil
	end
	local ok, countdowns = pcall(countdownUI.GetCountdowns)
	if not ok or type(countdowns) ~= "table" or countdowns.synced ~= true then
		return nil
	end
	if type(countdowns.nightlyRotationAt) ~= "number" then
		return nil
	end
	return countdowns.nightlyRotationAt
end

local function onRenderStepped()
	local gui = wallGui

	-- Countdown + slab upkeep, once per displayed second (per-RenderStepped
	-- second tick — no per-second remotes, §7).
	local now = serverNow()
	local second = math.floor(now)
	if second ~= lastCountdownSecond then
		lastCountdownSecond = second
		ensureWallAdornee()
		local label = countdownLabel
		if label ~= nil then
			local rotationAt = readNightlyRotationAt()
			if rotationAt ~= nil then
				label.Text = formatRotation(rotationAt - now)
			else
				label.Text = "Rotates in --d --h --m"
			end
		end
	end

	-- Viewport spin: skipped entirely while the gui is hidden or the camera is
	-- beyond the animate radius (same cull discipline as podium displays).
	if gui == nil or not gui.Enabled then
		return
	end
	local slab = wallPart
	local camera = Workspace.CurrentCamera
	if slab == nil or camera == nil then
		return
	end
	if (camera.CFrame.Position - slab.Position).Magnitude > LobbyConfig.DISPLAY_ANIMATE_RADIUS_STUDS then
		return
	end

	local angleBase = os.clock() * math.rad(LobbyConfig.DISPLAY_SPIN_DEGREES_PER_SECOND)
	for _, spinner in spinners do
		local angle = angleBase + spinner.phase
		spinner.camera.CFrame = CFrame.lookAt(
			spinner.focus
				+ Vector3.new(math.cos(angle) * spinner.distance, spinner.height, math.sin(angle) * spinner.distance),
			spinner.focus
		)
	end
end

--------------------------------------------------------------------------------
-- Loader lifecycle
--------------------------------------------------------------------------------

function BrainrotWallUI:Init(registry: any)
	-- Init must not yield (§A loader contract); everything heavy is in Start.
	registryRef = registry
end

function BrainrotWallUI:Start()
	local playerGui = LocalPlayer:WaitForChild("PlayerGui")

	local gui = buildWallGui()
	gui.Parent = playerGui -- client-side render; the wall slab stays bare
	wallGui = gui

	ensureWallAdornee()
	CollectionService:GetInstanceAddedSignal(TAG_WALL):Connect(ensureWallAdornee)

	-- Owned-state checklist: initial fill + refresh on the local player's
	-- shelf/collection changes (ShelfChanged fires on place/remove/auto-prune;
	-- LockerChanged is the owner-only push that covers unboxes — a fresh pull
	-- checks off on the wall without waiting for a shelf edit).
	refreshOwned()
	Remotes.GetEvent("ShelfChanged").OnClientEvent:Connect(function(payload: any)
		if type(payload) == "table" and payload.ownerUserId == LocalPlayer.UserId then
			refreshOwned()
		end
	end)
	Remotes.GetEvent("LockerChanged").OnClientEvent:Connect(function()
		refreshOwned()
	end)

	RunService.RenderStepped:Connect(onRenderStepped)
end

return BrainrotWallUI
