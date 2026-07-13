--!strict
-- RESCUE THE BRAINROTS! — MinimapController (PASS_MINIMAP game pass).
-- A live top-down minimap shown DURING a shift to owners of the Floor Minimap
-- pass. It renders:
--   * the seeded floor LAYOUT — the generated room walls, read straight from the
--     workspace "Floor" model and projected top-down (rebuilt periodically so it
--     fills in as streaming brings rooms into range);
--   * the LOCAL player (bright dot) and every OTHER player (dim dots);
--   * the EXTRACTION exit (gold marker), found via the "ExtractionDock" tag.
-- It deliberately NEVER shows crates — the haul is still something you earn by
-- exploring. Pure client GUI; reads no crate data at all.
--
-- Gating: the server publishes the "OwnsMinimap" player attribute
-- (MonetizationService, from OwnsPass("PASS_MINIMAP")). No pass -> no map.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Net"):WaitForChild("Remotes"))

local LocalPlayer = Players.LocalPlayer

--------------------------------------------------------------------------------
-- Tuning (cosmetic, this module's domain)
--------------------------------------------------------------------------------

local MAP_PX = 200 -- minimap panel size (square)
local MAP_MARGIN_PX = 16
local WALL_REBUILD_SECONDS = 1.5 -- re-scan the floor (streaming fills in over time)
local DOT_PX = 8
local EXIT_PX = 12
local MAX_WALLS = 600 -- perf guard on the static layer

-- A part counts as a "wall" of the layout: tall enough to be a wall, and thin on
-- at least one horizontal axis (so we skip floors/ceilings/markers/props).
local WALL_MIN_HEIGHT = 6
local WALL_MAX_THICKNESS = 3

local COLOR_PANEL = Color3.fromRGB(14, 14, 18)
local COLOR_WALL = Color3.fromRGB(120, 124, 150)
local COLOR_LOCAL = Color3.fromRGB(90, 220, 255)
local COLOR_OTHER = Color3.fromRGB(220, 220, 220)
local COLOR_EXIT = Color3.fromRGB(235, 190, 52)
local COLOR_BORDER = Color3.fromRGB(80, 80, 95)

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local MinimapController = {}

local panel: Frame? = nil
local wallLayer: Frame? = nil
local dotLayer: Frame? = nil

local shiftActive = false
local lastWallBuild = 0
-- Cached floor projection basis (XZ -> [0,1]) from the Floor model bounds.
local floorMin: Vector2? = nil
local floorSpan: Vector2? = nil

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function ownsMinimap(): boolean
	return LocalPlayer:GetAttribute("OwnsMinimap") == true
end

local function findFloorModel(): Model?
	local floor = Workspace:FindFirstChild("Floor")
	return if floor ~= nil and floor:IsA("Model") then floor else nil
end

-- Refresh the world->map projection from the Floor model's XZ bounding box.
local function refreshFloorBounds(): boolean
	local floor = findFloorModel()
	if floor == nil then
		return false
	end
	local ok, cf, size = pcall(function()
		return floor:GetBoundingBox()
	end)
	if not ok or typeof(size) ~= "Vector3" then
		return false
	end
	local center = (cf :: CFrame).Position
	-- A little padding so edge walls/dots aren't clipped at the panel border.
	local halfX = size.X / 2 + 4
	local halfZ = size.Z / 2 + 4
	floorMin = Vector2.new(center.X - halfX, center.Z - halfZ)
	floorSpan = Vector2.new(halfX * 2, halfZ * 2)
	return true
end

-- World XZ -> minimap pixel offset (nil when out of the known floor bounds /
-- before the bounds are known).
local function projectXZ(worldX: number, worldZ: number): Vector2?
	local origin = floorMin
	local span = floorSpan
	if origin == nil or span == nil or span.X <= 0 or span.Y <= 0 then
		return nil
	end
	local u = (worldX - origin.X) / span.X
	local v = (worldZ - origin.Y) / span.Y
	return Vector2.new(u * MAP_PX, v * MAP_PX)
end

local function makeDot(parent: Instance, name: string, sizePx: number, color: Color3): Frame
	local dot = Instance.new("Frame")
	dot.Name = name
	dot.AnchorPoint = Vector2.new(0.5, 0.5)
	dot.Size = UDim2.fromOffset(sizePx, sizePx)
	dot.BackgroundColor3 = color
	dot.BorderSizePixel = 0
	dot.ZIndex = 4
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = dot
	dot.Parent = parent
	return dot
end

--------------------------------------------------------------------------------
-- Static layer: the seeded floor walls (rebuilt as streaming fills the floor in)
--------------------------------------------------------------------------------

local function rebuildWalls()
	local layer = wallLayer
	if layer == nil then
		return
	end
	if not refreshFloorBounds() then
		return
	end
	local floor = findFloorModel()
	if floor == nil then
		return
	end

	for _, child in layer:GetChildren() do
		child:Destroy()
	end

	local drawn = 0
	for _, part in floor:GetDescendants() do
		if drawn >= MAX_WALLS then
			break
		end
		if not part:IsA("BasePart") then
			continue
		end
		local size = part.Size
		-- Walls only: tall, and thin on at least one horizontal axis.
		if size.Y < WALL_MIN_HEIGHT then
			continue
		end
		if size.X > WALL_MAX_THICKNESS and size.Z > WALL_MAX_THICKNESS then
			continue
		end
		local pos = part.Position
		local center = projectXZ(pos.X, pos.Z)
		if center == nil then
			continue
		end
		local span = floorSpan :: Vector2
		local wPx = math.max(2, (size.X / span.X) * MAP_PX)
		local hPx = math.max(2, (size.Z / span.Y) * MAP_PX)
		local seg = Instance.new("Frame")
		seg.Name = "Wall"
		seg.AnchorPoint = Vector2.new(0.5, 0.5)
		seg.Position = UDim2.fromOffset(center.X, center.Y)
		seg.Size = UDim2.fromOffset(wPx, hPx)
		seg.BackgroundColor3 = COLOR_WALL
		seg.BackgroundTransparency = 0.25
		seg.BorderSizePixel = 0
		seg.ZIndex = 2
		seg.Parent = layer
		drawn += 1
	end
end

--------------------------------------------------------------------------------
-- Dynamic layer: players + the exit, refreshed every frame while visible
--------------------------------------------------------------------------------

local exitDot: Frame? = nil
local playerDots: { [Player]: Frame } = {}

local function updateExit()
	local layer = dotLayer
	if layer == nil then
		return
	end
	local zone: BasePart? = nil
	for _, tagged in CollectionService:GetTagged("ExtractionDock") do
		if tagged:IsA("BasePart") then
			zone = tagged
			break
		end
	end
	if zone == nil then
		if exitDot ~= nil then
			exitDot.Visible = false
		end
		return
	end
	local p = projectXZ(zone.Position.X, zone.Position.Z)
	if p == nil then
		return
	end
	if exitDot == nil then
		local created = makeDot(layer, "Exit", EXIT_PX, COLOR_EXIT)
		created.ZIndex = 5
		exitDot = created
	end
	local dot = exitDot :: Frame
	dot.Visible = true
	dot.Position = UDim2.fromOffset(p.X, p.Y)
end

local function updatePlayers()
	local layer = dotLayer
	if layer == nil then
		return
	end
	local seen: { [Player]: boolean } = {}
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root == nil or not root:IsA("BasePart") then
			continue
		end
		local p = projectXZ(root.Position.X, root.Position.Z)
		if p == nil then
			continue
		end
		seen[player] = true
		local isLocal = player == LocalPlayer
		local dot = playerDots[player]
		if dot == nil then
			dot = makeDot(
				layer,
				`Dot_{player.UserId}`,
				if isLocal then DOT_PX + 2 else DOT_PX,
				if isLocal then COLOR_LOCAL else COLOR_OTHER
			)
			dot.ZIndex = if isLocal then 7 else 6
			playerDots[player] = dot
		end
		dot.Visible = true
		dot.Position = UDim2.fromOffset(p.X, p.Y)
	end
	-- Hide dots for players not currently on the floor.
	for player, dot in playerDots do
		if not seen[player] then
			dot.Visible = false
		end
	end
end

local function setVisible(visible: boolean)
	local gui = panel
	if gui ~= nil then
		gui.Visible = visible
	end
end

--------------------------------------------------------------------------------
-- GUI
--------------------------------------------------------------------------------

local function buildGui()
	local playerGui = LocalPlayer:WaitForChild("PlayerGui")

	local gui = Instance.new("ScreenGui")
	gui.Name = "MinimapUI"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 30
	gui.IgnoreGuiInset = false
	gui.Enabled = true

	local frame = Instance.new("Frame")
	frame.Name = "Panel"
	frame.AnchorPoint = Vector2.new(1, 0)
	frame.Position = UDim2.new(1, -MAP_MARGIN_PX, 0, MAP_MARGIN_PX)
	frame.Size = UDim2.fromOffset(MAP_PX, MAP_PX)
	frame.BackgroundColor3 = COLOR_PANEL
	frame.BackgroundTransparency = 0.2
	frame.BorderSizePixel = 0
	frame.Visible = false
	frame.ClipsDescendants = true
	frame.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = frame
	local stroke = Instance.new("UIStroke")
	stroke.Color = COLOR_BORDER
	stroke.Thickness = 1.5
	stroke.Parent = frame

	local walls = Instance.new("Frame")
	walls.Name = "Walls"
	walls.BackgroundTransparency = 1
	walls.Size = UDim2.fromScale(1, 1)
	walls.Parent = frame

	local dots = Instance.new("Frame")
	dots.Name = "Dots"
	dots.BackgroundTransparency = 1
	dots.Size = UDim2.fromScale(1, 1)
	dots.Parent = frame

	gui.Parent = playerGui

	panel = frame
	wallLayer = walls
	dotLayer = dots
end

--------------------------------------------------------------------------------
-- Remote handlers
--------------------------------------------------------------------------------

local function onShiftState(payload: any)
	if type(payload) ~= "table" or type(payload.state) ~= "string" then
		return
	end
	shiftActive = payload.state == "Active"
	if not shiftActive then
		setVisible(false)
	end
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function MinimapController:Init(_registry: any) end

function MinimapController:Start()
	buildGui()

	Remotes.GetEvent("ShiftState").OnClientEvent:Connect(onShiftState)

	-- Re-evaluate visibility when the pass attribute lands (purchase / join sync).
	LocalPlayer:GetAttributeChangedSignal("OwnsMinimap"):Connect(function()
		if not (shiftActive and ownsMinimap()) then
			setVisible(false)
		end
	end)

	RunService.Heartbeat:Connect(function()
		local shouldShow = shiftActive and ownsMinimap()
		if not shouldShow then
			setVisible(false)
			return
		end
		-- Rebuild the static wall layer occasionally (streaming-aware).
		local now = os.clock()
		if now - lastWallBuild >= WALL_REBUILD_SECONDS or floorMin == nil then
			lastWallBuild = now
			rebuildWalls()
		end
		if floorMin == nil then
			setVisible(false) -- floor not resolvable yet
			return
		end
		setVisible(true)
		updateExit()
		updatePlayers()
	end)
end

return MinimapController
