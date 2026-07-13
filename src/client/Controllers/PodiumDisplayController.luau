--!strict
-- CRYPTLINGS: NIGHT SHIFT — PodiumDisplayController (street-lobby rebuild,
-- Lobby SOP §3.5 client-built displays, §4.2 podium template, §4.5 perf rules).
-- The server replicates podium pads ONLY (tag "ShelfSlotPad" + attrs Filled /
-- CryptlingId / OwnerUserId / SlotId — ShelfRoomBuilder's existing pad
-- contract); this controller builds every pet figure locally from its
-- RarityTable recipe (THE render spec), so display models cost zero
-- replication (SOP §10 "pet display models: client-built only").
--
--   * Discovery is streaming-safe: CollectionService:GetTagged + the
--     added/removed signals (they fire on stream-in/out too), plus per-pad
--     GetAttributeChangedSignal("CryptlingId")/("Filled") — never polling.
--   * Filled pad -> greybox figure (DISPLAY_SCALE 0.42 ported from the
--     retired server-side renderer, height-clamped, decor-flagged parts)
--     pivoted DISPLAY_PIVOT_HEIGHT above the rarity ring, RarityFX tier
--     signature applied, tagged "ShelfDisplay" with attrs OwnerUserId /
--     SlotId / CryptlingId (preserves ShelfUI's detail-card contract), plus
--     a name + rarity BillboardGui.
--   * Empty pad -> gray ring only, no billboard (Addendum 2 R3-4).
--   * ONE frame loop animates spin + bob for pads within
--     DISPLAY_ANIMATE_RADIUS of the camera (static beyond) and gates RarityFX
--     ParticleEmitters to RARITY_FX_RADIUS. Zero scripts inside display
--     models; per-pad cost is the two attribute connections only.
--   * Mythical figures opt out of the local spin/bob — RarityFX owns their
--     motion (same exclusion the old server renderer made).
--
-- Public API (Controllers.Get("PodiumDisplayController")):
--   PodiumDisplayController.GetActiveDisplayCount() -> number  -- QA/debug

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local LobbyConfig = require(Shared:WaitForChild("Config"):WaitForChild("LobbyConfig"))
local RarityFX = require(Shared:WaitForChild("Config"):WaitForChild("RarityFX"))
local RarityTable = require(Shared:WaitForChild("Config"):WaitForChild("RarityTable"))

local LocalPlayer = Players.LocalPlayer

--------------------------------------------------------------------------------
-- Tuning (display constants of record live in LobbyConfig — SOP §9)
--------------------------------------------------------------------------------

-- 3D contract (produced by ShelfRoomBuilder, also consumed by ShelfUI).
local TAG_SLOT_PAD = "ShelfSlotPad"
local TAG_DISPLAY = "ShelfDisplay"
local ATTR_OWNER_USER_ID = "OwnerUserId"
local ATTR_SLOT_ID = "SlotId"
local ATTR_CRYPTLING_ID = "CryptlingId"
local ATTR_FILLED = "Filled"

-- Figure sizing, ported verbatim from the retired server-side renderer.
local DISPLAY_SCALE = 0.42
local MAX_FIGURE_HEIGHT = 2.6

local SPIN_DEGREES_PER_SECOND = LobbyConfig.DISPLAY_SPIN_DEGREES_PER_SECOND -- 20
local BOB_AMPLITUDE_STUDS = LobbyConfig.DISPLAY_BOB_AMPLITUDE_STUDS -- +/- 0.25
local BOB_PERIOD_SECONDS = LobbyConfig.DISPLAY_BOB_PERIOD_SECONDS -- 2
local ANIMATE_RADIUS_STUDS = LobbyConfig.DISPLAY_ANIMATE_RADIUS_STUDS -- 120
local FX_RADIUS_STUDS = LobbyConfig.RARITY_FX_RADIUS_STUDS -- 50
local PIVOT_HEIGHT_STUDS = LobbyConfig.PODIUM.DISPLAY_PIVOT_HEIGHT_STUDS -- 1.5
local LABEL_MAX_DISTANCE = LobbyConfig.BILLBOARD_MAX_DISTANCE.PODIUM
local GUI_BRIGHTNESS = LobbyConfig.SURFACE_GUI.BRIGHTNESS -- ~2 (SOP §11.1)

-- Emitter Enabled flips are throttled — they never need frame accuracy.
local FX_GATE_SECONDS = 0.25

-- Billboard colors (filled pads only — empty pads render no billboard,
-- Addendum 2 R3-4).
local COLOR_TEXT_WARM =
	Color3.fromRGB(LobbyConfig.SIGN_TEXT_COLOR.R, LobbyConfig.SIGN_TEXT_COLOR.G, LobbyConfig.SIGN_TEXT_COLOR.B)
local COLOR_STROKE = Color3.fromRGB(0, 0, 0)

local TWO_PI = 2 * math.pi

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

type DisplayEntry = {
	model: Model,
	baseCF: CFrame,
	basePosition: Vector3,
	phase: number, -- slot index: per-podium spin/bob phase offset (SOP §4.2)
	animate: boolean, -- false for Mythical (RarityFX owns its motion)
	animating: boolean,
	emitters: { ParticleEmitter },
	fxEnabled: boolean,
	cryptlingId: string,
}

-- Billboard fields are nil while the pad is empty: the gui is lazy-created on
-- first fill and destroyed on empty, so no BillboardGui ever exists over a
-- gray ring (Addendum 2 R3-4).
type PadEntry = {
	pad: BasePart,
	connections: { RBXScriptConnection },
	display: DisplayEntry?,
	billboard: BillboardGui?,
	nameLabel: TextLabel?,
	rarityLabel: TextLabel?,
}

local PodiumDisplayController = {}

local pads: { [BasePart]: PadEntry } = {}
local displayFolder: Folder? = nil
local billboardFolder: Folder? = nil
local fxGateAccumulator = 0
local warnedUnknownIds: { [string]: boolean } = {}

--------------------------------------------------------------------------------
-- Greybox figure assembly (recipe = THE render spec, CONTRACTS §E)
--------------------------------------------------------------------------------

-- Display parts are pure decor: never collide, touch, query, or cast shadows
-- (SOP §4.5 display performance rules).
local function makeFigurePart(parent: Instance, shape: string, size: Vector3, cframe: CFrame, color: Color3): BasePart
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
	part.CastShadow = false
	part.Material = Enum.Material.SmoothPlastic
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

local function slotIndexOf(slotId: string): number
	local digits = string.match(slotId, "%d+")
	local index = if digits ~= nil then tonumber(digits) else nil
	return index or 0
end

local function buildDisplay(pad: BasePart, cryptlingId: string): DisplayEntry?
	local folder = displayFolder
	if folder == nil then
		return nil
	end
	local def: any = RarityTable.GetCryptling(cryptlingId)
	if def == nil then
		if not warnedUnknownIds[cryptlingId] then
			warnedUnknownIds[cryptlingId] = true
			warn(`[PodiumDisplayController] unknown cryptlingId "{cryptlingId}" on pad — skipped`)
		end
		return nil
	end

	local slotIdAttr = pad:GetAttribute(ATTR_SLOT_ID)
	local slotId: string = if type(slotIdAttr) == "string" then slotIdAttr else "s0"
	local ownerAttr = pad:GetAttribute(ATTR_OWNER_USER_ID)
	local ownerUserId: number = if type(ownerAttr) == "number" then ownerAttr else 0

	-- Scale to display size, clamped so the tallest recipes never tower.
	local scale = DISPLAY_SCALE * (if type(def.scale) == "number" and def.scale > 0 then def.scale else 1)
	local tallest = 0
	for _, recipePart in def.recipe do
		local ok, top = pcall(function()
			return (recipePart.offset :: CFrame).Position.Y + (recipePart.size :: Vector3).Y / 2
		end)
		if ok and type(top) == "number" then
			tallest = math.max(tallest, top)
		end
	end
	if tallest > 0 and tallest * scale > MAX_FIGURE_HEIGHT then
		scale = MAX_FIGURE_HEIGHT / tallest
	end

	-- Pivot DISPLAY_PIVOT_HEIGHT above the rarity ring, facing the lot front
	-- (pads inherit the lot frame whose -Z faces the street).
	local baseCF = pad.CFrame * CFrame.new(0, PIVOT_HEIGHT_STUDS, 0)

	local model = Instance.new("Model")
	model.Name = `Display_{slotId}`
	for _, recipePart in def.recipe do
		local offset = recipePart.offset :: CFrame
		local scaledOffset = CFrame.new(offset.Position * scale) * offset.Rotation
		makeFigurePart(
			model,
			recipePart.shape,
			(recipePart.size :: Vector3) * scale,
			baseCF * scaledOffset,
			(recipePart.colorOverride :: Color3?) or (def.color :: Color3)
		)
	end
	model.WorldPivot = baseCF

	-- ShelfUI's detail-card contract: tag + the same three attrs the old
	-- server-built displays carried.
	model:SetAttribute(ATTR_OWNER_USER_ID, ownerUserId)
	model:SetAttribute(ATTR_SLOT_ID, slotId)
	model:SetAttribute(ATTR_CRYPTLING_ID, cryptlingId)
	CollectionService:AddTag(model, TAG_DISPLAY)
	model.Parent = folder

	-- Tier signature AFTER parenting (Mythical's hue/bob loop exits when the
	-- model is unparented). Emitters start disabled; the frame loop enables
	-- them only within FX_RADIUS of the camera (SOP §10 sparkle rule).
	RarityFX.Apply(model, def)
	local emitters: { ParticleEmitter } = {}
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("ParticleEmitter") then
			descendant.Enabled = false
			table.insert(emitters, descendant)
		end
	end

	return {
		model = model,
		baseCF = baseCF,
		basePosition = baseCF.Position,
		phase = slotIndexOf(slotId),
		animate = def.rarity ~= "Mythical",
		animating = false,
		emitters = emitters,
		fxEnabled = false,
		cryptlingId = cryptlingId,
	}
end

--------------------------------------------------------------------------------
-- Billboards (filled pads only — lazy-created on first fill, destroyed when
-- the pad empties; Addendum 2 R3-4)
--------------------------------------------------------------------------------

local function makeBillboardLabel(parent: Instance, name: string, yScale: number, heightScale: number): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = name
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, heightScale)
	label.Position = UDim2.fromScale(0, yScale)
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.TextColor3 = COLOR_TEXT_WARM
	local stroke = Instance.new("UIStroke")
	stroke.Color = COLOR_STROKE
	stroke.Thickness = 2
	stroke.Parent = label
	label.Parent = parent
	return label
end

local function makeBillboard(pad: BasePart): (BillboardGui, TextLabel, TextLabel)
	local gui = Instance.new("BillboardGui")
	gui.Name = "PodiumLabel"
	gui.Adornee = pad
	gui.Size = UDim2.fromScale(7, 2.2)
	gui.StudsOffsetWorldSpace = Vector3.new(0, PIVOT_HEIGHT_STUDS + MAX_FIGURE_HEIGHT + 0.8, 0)
	gui.AlwaysOnTop = false -- SOP §4.2
	gui.LightInfluence = 0 -- the #1 night-sign bug (SOP §11.1)
	gui.Brightness = GUI_BRIGHTNESS
	gui.MaxDistance = LABEL_MAX_DISTANCE -- 80: podium labels cull here (SOP §4.2)
	local nameLabel = makeBillboardLabel(gui, "NameLine", 0, 0.58)
	local rarityLabel = makeBillboardLabel(gui, "RarityLine", 0.6, 0.4)
	gui.Parent = billboardFolder
	return gui, nameLabel, rarityLabel
end

local function setBillboardFilled(entry: PadEntry, def: any)
	local nameLabel = entry.nameLabel
	local rarityLabel = entry.rarityLabel
	if nameLabel == nil or rarityLabel == nil then
		return
	end
	local rarity: string = def.rarity
	local rarityColor3 = (RarityTable.RARITY_COLORS :: any)[rarity]
	local rarityColor: Color3 = if typeof(rarityColor3) == "Color3" then rarityColor3 else COLOR_TEXT_WARM
	local rarityWord = (RarityTable.RARITY_DISPLAY :: any)[rarity]
	nameLabel.Text = if type(def.name) == "string" then def.name else tostring(def.id)
	nameLabel.TextColor3 = rarityColor
	rarityLabel.Text = if type(rarityWord) == "string" then rarityWord else rarity
	rarityLabel.TextColor3 = rarityColor
end

--------------------------------------------------------------------------------
-- Pad lifecycle
--------------------------------------------------------------------------------

local function clearDisplay(entry: PadEntry)
	local display = entry.display
	if display == nil then
		return
	end
	display.model:Destroy()
	entry.display = nil
end

-- Empty pad = gray ring only: the billboard (if any) is destroyed outright,
-- never left disabled (Addendum 2 R3-4).
local function clearBillboard(entry: PadEntry)
	local billboard = entry.billboard
	if billboard == nil then
		return
	end
	billboard:Destroy()
	entry.billboard = nil
	entry.nameLabel = nil
	entry.rarityLabel = nil
end

local function refreshPad(pad: BasePart)
	local entry = pads[pad]
	if entry == nil then
		return
	end
	local filled = pad:GetAttribute(ATTR_FILLED) == true
	local idAttr = pad:GetAttribute(ATTR_CRYPTLING_ID)
	local wantId: string? = if filled and type(idAttr) == "string" and idAttr ~= "" then idAttr else nil

	local current = entry.display
	if current ~= nil and (wantId == nil or current.cryptlingId ~= wantId) then
		clearDisplay(entry)
		current = nil
	end
	if wantId ~= nil and current == nil then
		entry.display = buildDisplay(pad, wantId)
	end

	local refreshed = entry.display
	if refreshed ~= nil then
		-- Lazy-create the label on first fill; refresh the copy on swaps.
		if entry.billboard == nil then
			local billboard, nameLabel, rarityLabel = makeBillboard(pad)
			entry.billboard = billboard
			entry.nameLabel = nameLabel
			entry.rarityLabel = rarityLabel
		end
		setBillboardFilled(entry, RarityTable.GetCryptling(refreshed.cryptlingId))
	else
		clearBillboard(entry)
	end
end

local function watchPad(instance: Instance)
	if not instance:IsA("BasePart") then
		return
	end
	if pads[instance] ~= nil or billboardFolder == nil or displayFolder == nil then
		return
	end
	local entry: PadEntry = {
		pad = instance,
		connections = {},
		display = nil,
		billboard = nil,
		nameLabel = nil,
		rarityLabel = nil,
	}
	pads[instance] = entry
	table.insert(
		entry.connections,
		instance:GetAttributeChangedSignal(ATTR_CRYPTLING_ID):Connect(function()
			refreshPad(instance)
		end)
	)
	table.insert(
		entry.connections,
		instance:GetAttributeChangedSignal(ATTR_FILLED):Connect(function()
			refreshPad(instance)
		end)
	)
	refreshPad(instance)
end

local function unwatchPad(instance: Instance)
	if not instance:IsA("BasePart") then
		return
	end
	local entry = pads[instance]
	if entry == nil then
		return
	end
	pads[instance] = nil
	for _, connection in entry.connections do
		connection:Disconnect()
	end
	clearDisplay(entry)
	clearBillboard(entry)
end

--------------------------------------------------------------------------------
-- The ONE frame loop: spin/bob within the animate radius, emitter gating
-- within the FX radius, static (and dark) beyond (SOP §4.2/§10)
--------------------------------------------------------------------------------

local function onFrame(deltaTime: number)
	local camera = Workspace.CurrentCamera
	if camera == nil then
		return
	end
	local cameraPosition = camera.CFrame.Position
	local now = os.clock()

	fxGateAccumulator += deltaTime
	local gateFx = fxGateAccumulator >= FX_GATE_SECONDS
	if gateFx then
		fxGateAccumulator = 0
	end

	for _, entry in pads do
		local display = entry.display
		if display == nil then
			continue
		end
		local distance = (display.basePosition - cameraPosition).Magnitude
		if display.animate then
			if distance <= ANIMATE_RADIUS_STUDS then
				local yaw = math.rad(now * SPIN_DEGREES_PER_SECOND + display.phase * 24)
				local bob = math.sin(now / BOB_PERIOD_SECONDS * TWO_PI + display.phase) * BOB_AMPLITUDE_STUDS
				display.model:PivotTo(display.baseCF * CFrame.new(0, bob, 0) * CFrame.Angles(0, yaw, 0))
				display.animating = true
			elseif display.animating then
				display.model:PivotTo(display.baseCF) -- park in the rest pose
				display.animating = false
			end
		end
		if gateFx and #display.emitters > 0 then
			local enable = distance <= FX_RADIUS_STUDS
			if enable ~= display.fxEnabled then
				display.fxEnabled = enable
				for _, emitter in display.emitters do
					emitter.Enabled = enable
				end
			end
		end
	end
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

function PodiumDisplayController.GetActiveDisplayCount(): number
	local count = 0
	for _, entry in pads do
		if entry.display ~= nil then
			count += 1
		end
	end
	return count
end

--------------------------------------------------------------------------------
-- Loader lifecycle
--------------------------------------------------------------------------------

function PodiumDisplayController:Init()
	-- Connections only (Init must not yield). Pads tagged before Start's
	-- folders exist are picked up by the Start sweep below.
	CollectionService:GetInstanceAddedSignal(TAG_SLOT_PAD):Connect(function(instance: Instance)
		-- Deferred so a just-streamed pad's attributes replicate before we read.
		task.defer(watchPad, instance)
	end)
	CollectionService:GetInstanceRemovedSignal(TAG_SLOT_PAD):Connect(unwatchPad)
end

function PodiumDisplayController:Start()
	-- Client-local containers: figures in Workspace, label guis in PlayerGui
	-- (ShelfUI worldGui convention — never mutate server-owned parts).
	local figures = Instance.new("Folder")
	figures.Name = "PodiumDisplays"
	figures.Parent = Workspace
	displayFolder = figures

	local playerGui = LocalPlayer:WaitForChild("PlayerGui")
	local guis = Instance.new("Folder")
	guis.Name = "PodiumDisplayGui"
	guis.Parent = playerGui
	billboardFolder = guis

	-- Initial sweep: lots may already be streamed in by the time we run.
	for _, instance in CollectionService:GetTagged(TAG_SLOT_PAD) do
		watchPad(instance)
	end

	RunService.Heartbeat:Connect(onFrame)
end

return PodiumDisplayController
