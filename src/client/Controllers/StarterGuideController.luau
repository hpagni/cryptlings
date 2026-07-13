--!strict
-- CRYPTLINGS: NIGHT SHIFT — StarterGuideController (R7 Fix #4, Lane B).
-- The chained step machine that runs ONCE for a brand-new player right after
-- the WELCOME panel is dismissed (WelcomeController hands off via Start). It
-- walks the kid through their free guaranteed-rare starter case, one simple
-- action at a time, using PASSIVE guidance only (no blocking modals) in the same
-- non-blocking style as OnboardingController:
--
--   1. OPEN LOCKER  — auto-open the locker (LockerUI.Open) so the free case is
--      right there, then a friendly "tap your free box to open it!" subtitle.
--   2. OPEN CASE    — wait for the unbox reveal (detected via LockerChanged: the
--      case count drops as the box is opened) -> advance.
--   3. PODIUM       — a world billboard marker on the player's first EMPTY shelf
--      slot pad ("put your pet here!"), advance on ShelfChanged (a slot fills).
--   4. EQUIP        — pulse the on-screen PETS chip ("tap your pet to equip!"),
--      advance when Pet.GetState reports an equipped pet.
--   5. CLOCK IN     — a screen-edge arrow + world billboard at the factory
--      CLOCK IN zone with a "now go clock in at the factory!" subtitle. This
--      hands off to the existing in-shift OnboardingBeat (the foreman takes over
--      from clock-in onward).
--
-- AUDIENCE = KIDS: every subtitle is one short, friendly instruction. Each step
-- has a LOCAL failsafe timer so a missed detection signal can never soft-lock —
-- the guide always advances and always tears down. Runs once per session; the
-- once-EVER gate is server-side (grant-once + welcomeShown).
--
-- Public API (Controllers.Get("StarterGuideController")):
--   StarterGuideController.Begin()  -- WelcomeController calls this on GOT IT.
--     (Deliberately NOT named Start: the loader calls the :Start lifecycle hook
--      on every controller, so the public kickoff must use a different name or
--      the guide would auto-launch on boot for everyone.)

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConstants = require(Shared:WaitForChild("Config"):WaitForChild("GameConstants"))
local Remotes = require(Shared:WaitForChild("Net"):WaitForChild("Remotes"))

local LocalPlayer = Players.LocalPlayer

--------------------------------------------------------------------------------
-- Contract names (must match the world/UI contracts the other lanes own)
--------------------------------------------------------------------------------

-- Shelf slot pads (ShelfUI's discovery contract): tag + attributes.
local TAG_SLOT_PAD = "ShelfSlotPad"
local ATTR_OWNER_USER_ID = "OwnerUserId"
-- Some slot generators flag occupancy; we also cross-check ShelfUI's known shelf.
local ATTR_SLOT_FILLED = "Filled"
local ATTR_SLOT_ID = "SlotId"

-- Factory clock-in geometry (QueuePadUI's contract).
local HUB_MODEL_NAME = "NightShiftHub"
local PAD_MODEL_NAME = "QueuePad"
local CLOCK_IN_ZONE_NAME = "ClockInZone"

-- PetUI's on-screen chip (the equip entry point).
local PET_CHIP_GUI_NAME = "PetChip"
local PET_CHIP_BUTTON_NAME = "Chip"

--------------------------------------------------------------------------------
-- Tuning (cosmetic, this module's domain)
--------------------------------------------------------------------------------

local TYPEWRITER_CHARS_PER_SECOND = 28
local BLIP_EVERY_GRAPHEMES = 2
local BLIP_SOUND_ID = "rbxasset://sounds/electronicpingshort.wav"
local BLIP_VOLUME = 0.22

local DESIGN_SHORT_AXIS_PX = 450
local UISCALE_MIN = 0.85
local UISCALE_MAX = 1.6

local OPEN_LOCKER_RETRY_SECONDS = 0.4 -- nudge the locker open until LockerUI exists
local OPEN_LOCKER_MAX_TRIES = 12
local DETECT_POLL_SECONDS = 0.3 -- generic detection cadence (covers equip via Pet.GetState)

-- Per-step local failsafes so a missed signal can never soft-lock the guide.
local STEP_FAILSAFE_SECONDS = 90
local CLOCK_IN_MARKER_SECONDS = 120 -- the final edge arrow / billboard lifetime

local DOCK_ARROW_EDGE_FRACTION = 0.36
local DOCK_ONSCREEN_HIDE_FRACTION = 0.30

local COLOR_PANEL = Color3.fromRGB(18, 20, 24)
local COLOR_ACCENT = Color3.fromRGB(120, 230, 140) -- friendly guidance green
local COLOR_MARKER = Color3.fromRGB(255, 224, 130)

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local StarterGuideController = {}

local registryRef: any = nil
local running = false
local started = false -- once-per-session guard

local gui: ScreenGui? = nil
local subtitleFrame: Frame? = nil
local subtitleLabel: TextLabel? = nil
local blipSound: Sound? = nil
local typeToken = 0

local fxFolder: Folder? = nil
local podiumMarkerPart: BasePart? = nil
local beaconHost: BasePart? = nil
local beaconRingConnection: RBXScriptConnection? = nil
local clockInArrivalActive = false -- guards the one-shot clock-in teardown

-- Forward declaration: buildPodiumBeacon (FX section) needs to reuse the teardown
-- defined later, so the upvalue must exist before either closure is created.
local clearPodiumMarker: () -> ()

local arrowFrame: Frame? = nil
local arrowConnection: RBXScriptConnection? = nil
local clockInMarkerPart: BasePart? = nil
local clockInPosition: Vector3? = nil

local pulseRing: UIStroke? = nil
local pulseTween: Tween? = nil

--------------------------------------------------------------------------------
-- GUI / FX scaffolding (lazy)
--------------------------------------------------------------------------------

local function applyUiScale(scale: UIScale)
	local camera = Workspace.CurrentCamera
	if camera == nil then
		return
	end
	local shortAxis = math.min(camera.ViewportSize.X, camera.ViewportSize.Y)
	if shortAxis <= 0 then
		return
	end
	scale.Scale = math.clamp(shortAxis / DESIGN_SHORT_AXIS_PX, UISCALE_MIN, UISCALE_MAX)
end

local function ensureGui(): ScreenGui
	local existing = gui
	if existing ~= nil and existing.Parent ~= nil then
		return existing
	end

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "StarterGuideGui"
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = true
	screenGui.DisplayOrder = 22 -- above the HUD, below the welcome modal (60)

	local scale = Instance.new("UIScale")
	scale.Parent = screenGui
	applyUiScale(scale)
	local camera = Workspace.CurrentCamera
	if camera ~= nil then
		camera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
			applyUiScale(scale)
		end)
	end

	-- Bottom-third subtitle bar (matches OnboardingController's passive style).
	local bar = Instance.new("Frame")
	bar.Name = "SubtitleBar"
	bar.AnchorPoint = Vector2.new(0.5, 1)
	bar.Position = UDim2.fromScale(0.5, 0.84)
	bar.Size = UDim2.fromScale(0.86, 0)
	bar.AutomaticSize = Enum.AutomaticSize.Y
	bar.BackgroundColor3 = COLOR_PANEL
	bar.BackgroundTransparency = 0.2
	bar.BorderSizePixel = 0
	bar.Visible = false
	bar.Parent = screenGui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 12)
	corner.Parent = bar

	local maxWidth = Instance.new("UISizeConstraint")
	maxWidth.MaxSize = Vector2.new(560, math.huge)
	maxWidth.Parent = bar

	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, 12)
	padding.PaddingBottom = UDim.new(0, 14)
	padding.PaddingLeft = UDim.new(0, 16)
	padding.PaddingRight = UDim.new(0, 16)
	padding.Parent = bar

	local text = Instance.new("TextLabel")
	text.Name = "Subtitle"
	text.BackgroundTransparency = 1
	text.Size = UDim2.fromScale(1, 0)
	text.AutomaticSize = Enum.AutomaticSize.Y
	text.Font = Enum.Font.GothamBold
	text.TextSize = 22
	text.TextColor3 = COLOR_ACCENT
	text.TextWrapped = true
	text.TextXAlignment = Enum.TextXAlignment.Center
	text.TextYAlignment = Enum.TextYAlignment.Center
	text.Text = ""
	text.Parent = bar

	local blip = Instance.new("Sound")
	blip.Name = "GuideBlip"
	blip.SoundId = BLIP_SOUND_ID
	blip.Volume = BLIP_VOLUME
	blip.Parent = screenGui

	local playerGui = LocalPlayer:WaitForChild("PlayerGui")
	screenGui.Parent = playerGui

	gui = screenGui
	subtitleFrame = bar
	subtitleLabel = text
	blipSound = blip
	return screenGui
end

local function ensureFxFolder(): Folder
	local existing = fxFolder
	if existing ~= nil and existing.Parent ~= nil then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = "StarterGuideClientFX"
	folder.Parent = Workspace
	fxFolder = folder
	return folder
end

--------------------------------------------------------------------------------
-- Subtitle (typewriter + friendly blip) — passive, never blocks input
--------------------------------------------------------------------------------

local function showSubtitle(text: string)
	ensureGui()
	local bar = subtitleFrame
	local label = subtitleLabel
	if bar == nil or label == nil then
		return
	end

	typeToken += 1
	local token = typeToken
	label.Text = text
	label.MaxVisibleGraphemes = 0
	bar.Visible = true

	task.spawn(function()
		local graphemeCount = utf8.len(text) or #text
		for index = 1, graphemeCount :: number do
			if typeToken ~= token then
				return
			end
			label.MaxVisibleGraphemes = index
			local blip = blipSound
			if blip ~= nil and index % BLIP_EVERY_GRAPHEMES == 0 then
				blip.PlaybackSpeed = 1 + math.random() * 0.4
				blip:Play()
			end
			task.wait(1 / TYPEWRITER_CHARS_PER_SECOND)
		end
		if typeToken == token then
			label.MaxVisibleGraphemes = -1
		end
	end)
end

local function hideSubtitle()
	typeToken += 1
	if subtitleFrame ~= nil then
		(subtitleFrame :: Frame).Visible = false
	end
end

--------------------------------------------------------------------------------
-- World billboard markers (client-local greybox, AlwaysOnTop pulse)
--------------------------------------------------------------------------------

local function makeMarkerPart(name: string, position: Vector3): BasePart
	local part = Instance.new("Part")
	part.Name = name
	part.Size = Vector3.one
	part.Position = position
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = 1
	part.Parent = ensureFxFolder()
	return part
end

local function makeBillboard(adornee: Instance, text: string, color: Color3): BillboardGui
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "StarterGuideMarker"
	billboard.Adornee = adornee
	billboard.Size = UDim2.fromOffset(210, 52)
	billboard.StudsOffset = Vector3.zero
	billboard.AlwaysOnTop = true
	billboard.MaxDistance = 600

	local label = Instance.new("TextLabel")
	label.Name = "MarkerText"
	label.BackgroundColor3 = COLOR_PANEL
	label.BackgroundTransparency = 0.25
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.GothamBold
	label.TextSize = 19
	label.TextColor3 = color
	label.TextWrapped = true
	label.Text = text
	label.Parent = billboard

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = label

	-- Soft pulse so the marker reads as "look here".
	TweenService:Create(
		label,
		TweenInfo.new(0.7, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ TextTransparency = 0.35 }
	):Play()

	billboard.Parent = adornee
	return billboard
end

--------------------------------------------------------------------------------
-- BIG AAA BEACON (the "pillar of light" over the chosen empty podium pad).
-- ONE host part parented to the fx folder, with all of pillar / beam / highlight
-- / ring / billboard as children so a single host:Destroy() cleans everything.
-- The rotating ring needs a RenderStepped connection, stored for teardown.
-- NO Light instances (the 50-light budget is full): Neon + Beam only.
--------------------------------------------------------------------------------

local BEACON_PILLAR_SIZE = Vector3.new(3, 60, 3)
local BEACON_PILLAR_HEIGHT = 30 -- center the 60-tall pillar above the pad
local BEACON_RING_RADIUS = 3.4
local BEACON_RING_SPIN_DPS = 60 -- degrees / second

local function buildPodiumBeacon(pad: BasePart)
	clearPodiumMarker() -- never stack two beacons

	-- Host anchored at the pad, parented to the fx folder. All beacon parts are
	-- children of the host so finish()/clearPodiumMarker destroy the whole thing.
	local host = Instance.new("Part")
	host.Name = "StarterGuideBeacon"
	host.Size = Vector3.one
	host.Position = pad.Position
	host.Anchored = true
	host.CanCollide = false
	host.CanQuery = false
	host.CanTouch = false
	host.Transparency = 1
	host.Parent = ensureFxFolder()

	-- 1) NEON PILLAR — tall glowing column, transparency breathing 0.4 <-> 0.8.
	local pillar = Instance.new("Part")
	pillar.Name = "Pillar"
	pillar.Size = BEACON_PILLAR_SIZE
	pillar.Position = pad.Position + Vector3.new(0, BEACON_PILLAR_HEIGHT, 0)
	pillar.Anchored = true
	pillar.CanCollide = false
	pillar.CanQuery = false
	pillar.CanTouch = false
	pillar.Material = Enum.Material.Neon
	pillar.Color = COLOR_ACCENT
	pillar.Transparency = 0.4
	pillar.Parent = host
	TweenService:Create(
		pillar,
		TweenInfo.new(0.9, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ Transparency = 0.8 }
	):Play()

	-- 2) BEAM SHAFT — two attachments (pad base + high above), bright FaceCamera beam.
	local baseAttachment = Instance.new("Attachment")
	baseAttachment.Name = "BeaconBase"
	baseAttachment.WorldPosition = pad.Position + Vector3.new(0, 1, 0)
	baseAttachment.Parent = host
	local topAttachment = Instance.new("Attachment")
	topAttachment.Name = "BeaconTop"
	topAttachment.WorldPosition = pad.Position + Vector3.new(0, 58, 0)
	topAttachment.Parent = host
	local beam = Instance.new("Beam")
	beam.Name = "Shaft"
	beam.Attachment0 = baseAttachment
	beam.Attachment1 = topAttachment
	beam.Color = ColorSequence.new(COLOR_ACCENT)
	beam.LightEmission = 1
	beam.FaceCamera = true
	beam.Width0 = 6
	beam.Width1 = 2
	beam.Transparency = NumberSequence.new(0.15)
	beam.Parent = host

	-- 3) HIGHLIGHT — OUR OWN, adornee = pad, AlwaysOnTop accent outline. We never
	-- enable the pad's shared EditGlow highlight (never leave shared state on).
	local highlight = Instance.new("Highlight")
	highlight.Name = "BeaconHighlight"
	highlight.Adornee = pad
	highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	highlight.FillColor = COLOR_ACCENT
	highlight.FillTransparency = 0.6
	highlight.OutlineColor = COLOR_ACCENT
	highlight.OutlineTransparency = 0
	highlight.Parent = host

	-- 4) ROTATING RING — thin Neon ring spun by ONE RenderStepped connection.
	local ring = Instance.new("Part")
	ring.Name = "Ring"
	ring.Shape = Enum.PartType.Cylinder
	ring.Size = Vector3.new(0.4, BEACON_RING_RADIUS * 2, BEACON_RING_RADIUS * 2)
	ring.Anchored = true
	ring.CanCollide = false
	ring.CanQuery = false
	ring.CanTouch = false
	ring.Material = Enum.Material.Neon
	ring.Color = COLOR_MARKER
	ring.Transparency = 0.25
	-- Lay the cylinder flat (axis vertical) so the disc hovers above the pad.
	local ringBase = CFrame.new(pad.Position + Vector3.new(0, 1, 0)) * CFrame.Angles(0, 0, math.rad(90))
	ring.CFrame = ringBase
	ring.Parent = host
	beaconRingConnection = RunService.RenderStepped:Connect(function(dt: number)
		if ring.Parent == nil then
			return
		end
		ring.CFrame = ring.CFrame * CFrame.Angles(math.rad(BEACON_RING_SPIN_DPS * dt), 0, 0)
	end)

	-- 5) KID LABEL — friendly "Put your pet here!" billboard floated above the
	-- pillar (host sits at pad level, so lift the label with StudsOffset).
	local label = makeBillboard(host, GameConstants.STARTER_GUIDE.PODIUM_MARKER, COLOR_MARKER)
	label.StudsOffset = Vector3.new(0, 6, 0)

	beaconHost = host
	podiumMarkerPart = host
end

-- A short satisfying confirm pop on the beacon's pad position when the action
-- gate fires (cosmetic feedback only; cleaned up on its own short lifetime).
local function playPodiumConfirm()
	local host = beaconHost
	local position = if host ~= nil then host.Position else nil
	if position == nil then
		-- Equip step: the podium beacon is already torn down, so pop at the
		-- player instead, so the kid still gets a satisfying confirm.
		local character = LocalPlayer.Character
		local hrp = character and character:FindFirstChild("HumanoidRootPart")
		if hrp ~= nil and hrp:IsA("BasePart") then
			position = (hrp :: BasePart).Position
		end
	end
	if position == nil then
		return
	end
	local pop = Instance.new("Part")
	pop.Name = "StarterGuideConfirm"
	pop.Shape = Enum.PartType.Ball
	pop.Size = Vector3.new(2, 2, 2)
	pop.Position = position + Vector3.new(0, 2, 0)
	pop.Anchored = true
	pop.CanCollide = false
	pop.CanQuery = false
	pop.CanTouch = false
	pop.Material = Enum.Material.Neon
	pop.Color = COLOR_ACCENT
	pop.Transparency = 0.1
	pop.Parent = ensureFxFolder()
	local grow = TweenService:Create(
		pop,
		TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = Vector3.new(8, 8, 8), Transparency = 1 }
	)
	grow.Completed:Connect(function()
		pop:Destroy()
	end)
	grow:Play()
end

--------------------------------------------------------------------------------
-- Screen-edge chevron arrow (points at an off-screen world target)
--------------------------------------------------------------------------------

local function buildArrowFrame(parent: ScreenGui): Frame
	local container = Instance.new("Frame")
	container.Name = "ClockInArrow"
	container.AnchorPoint = Vector2.new(0.5, 0.5)
	container.Size = UDim2.fromOffset(44, 44)
	container.BackgroundTransparency = 1
	container.Visible = false
	container.Parent = parent

	local barTop = Instance.new("Frame")
	barTop.Name = "BarTop"
	barTop.AnchorPoint = Vector2.new(0.5, 0.5)
	barTop.Position = UDim2.fromOffset(24, 13)
	barTop.Size = UDim2.fromOffset(26, 6)
	barTop.Rotation = 45
	barTop.BackgroundColor3 = COLOR_ACCENT
	barTop.BorderSizePixel = 0
	barTop.Parent = container

	local barBottom = barTop:Clone()
	barBottom.Name = "BarBottom"
	barBottom.Position = UDim2.fromOffset(24, 31)
	barBottom.Rotation = -45
	barBottom.Parent = container

	for _, bar in { barTop, barBottom } do
		TweenService:Create(
			bar,
			TweenInfo.new(0.6, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
			{ BackgroundTransparency = 0.45 }
		):Play()
	end
	return container
end

local function updateClockInArrow()
	local arrow = arrowFrame
	local target = clockInPosition
	local camera = Workspace.CurrentCamera
	if arrow == nil or target == nil or camera == nil then
		return
	end

	local viewport = camera.ViewportSize
	local point, onScreen = camera:WorldToViewportPoint(target)
	local center = Vector2.new(viewport.X / 2, viewport.Y / 2)
	local direction = Vector2.new(point.X, point.Y) - center
	if point.Z < 0 then
		direction = -direction -- behind the camera: point away from its mirror
	end

	local shortAxis = math.min(viewport.X, viewport.Y)
	if onScreen and direction.Magnitude < shortAxis * DOCK_ONSCREEN_HIDE_FRACTION then
		arrow.Visible = false -- target comfortably in view: the billboard carries it
		return
	end

	local unit = if direction.Magnitude > 1 then direction.Unit else Vector2.new(0, -1)
	local radius = shortAxis * DOCK_ARROW_EDGE_FRACTION
	arrow.Visible = true
	arrow.Position = UDim2.fromOffset(center.X + unit.X * radius, center.Y + unit.Y * radius)
	arrow.Rotation = math.deg(math.atan2(unit.Y, unit.X))
end

--------------------------------------------------------------------------------
-- PETS chip pulse (highlight ring on the on-screen equip chip)
--------------------------------------------------------------------------------

local function findPetChipButton(): GuiButton?
	local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if playerGui == nil then
		return nil
	end
	local chipGui = playerGui:FindFirstChild(PET_CHIP_GUI_NAME)
	if chipGui == nil then
		return nil
	end
	local button = chipGui:FindFirstChild(PET_CHIP_BUTTON_NAME, true)
	if button ~= nil and button:IsA("GuiButton") then
		return button
	end
	return nil
end

local function clearPetChipPulse()
	if pulseTween ~= nil then
		(pulseTween :: Tween):Cancel()
		pulseTween = nil
	end
	if pulseRing ~= nil then
		(pulseRing :: UIStroke):Destroy()
		pulseRing = nil
	end
end

local function startPetChipPulse()
	clearPetChipPulse()
	local button = findPetChipButton()
	if button == nil then
		return -- the subtitle carries it until the chip exists
	end
	local ring = Instance.new("UIStroke")
	ring.Name = "StarterGuidePulseRing"
	ring.Color = COLOR_ACCENT
	ring.Thickness = 3
	ring.Transparency = 0.1
	ring.Parent = button
	local pulse = TweenService:Create(
		ring,
		TweenInfo.new(0.7, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ Transparency = 0.7 }
	)
	pulse:Play()
	pulseRing = ring
	pulseTween = pulse
end

--------------------------------------------------------------------------------
-- Registry helpers
--------------------------------------------------------------------------------

local function getController(name: string): any
	if registryRef == nil or type(registryRef.Get) ~= "function" then
		return nil
	end
	return registryRef.Get(name)
end

-- Requests a SERVER-authoritative teleport. The teleport is an EFFECT (the reward
-- for the prior action), never a wait-gate: the client never sets a CFrame, it only
-- asks the server, which validates the gate/cursor and performs the PivotTo. Returns
-- true only on { ok = true }. A false result is non-fatal (the world guidance still
-- carries the step; the failsafe still backstops a softlock).
local function requestTeleport(fnName: string): boolean
	local ok, res = pcall(function()
		return Remotes.GetFunction(fnName):InvokeServer()
	end)
	return ok and type(res) == "table" and res.ok == true
end

-- Open the locker so the free case is right in front of the player. Retries a
-- few times in case LockerUI hasn't registered/built its chip yet.
local function openLocker()
	task.spawn(function()
		for _ = 1, OPEN_LOCKER_MAX_TRIES do
			local lockerUI = getController("LockerUI")
			if type(lockerUI) == "table" and type(lockerUI.Open) == "function" then
				local ok = pcall(lockerUI.Open)
				if ok then
					return
				end
			end
			task.wait(OPEN_LOCKER_RETRY_SECONDS)
		end
	end)
end

--------------------------------------------------------------------------------
-- Shelf slot discovery (the player's first EMPTY podium pad)
--------------------------------------------------------------------------------

local function isMyPad(part: Instance): boolean
	local owner = part:GetAttribute(ATTR_OWNER_USER_ID)
	return type(owner) == "number" and owner == LocalPlayer.UserId
end

-- Reads ShelfUI's known shelf (server state + optimistic) to learn which of the
-- local player's slots are filled, so we mark a genuinely-empty one.
local function filledSlotIds(): { [string]: boolean }
	local filled: { [string]: boolean } = {}
	local shelfUI = getController("ShelfUI")
	if type(shelfUI) == "table" and type(shelfUI.GetKnownShelf) == "function" then
		local ok, slots = pcall(shelfUI.GetKnownShelf, LocalPlayer.UserId)
		if ok and type(slots) == "table" then
			for slotId, cryptlingId in slots :: { [any]: any } do
				if type(slotId) == "string" and type(cryptlingId) == "string" then
					filled[slotId] = true
				end
			end
		end
	end
	return filled
end

-- The local player's first EMPTY shelf slot pad, or nil if none is discoverable.
local function findFirstEmptyOwnPad(): BasePart?
	local filled = filledSlotIds()
	local best: BasePart? = nil
	local bestSlot: string? = nil
	for _, instance in CollectionService:GetTagged(TAG_SLOT_PAD) do
		if instance:IsA("BasePart") and isMyPad(instance) then
			local slotId = instance:GetAttribute(ATTR_SLOT_ID)
			local padFilledAttr = instance:GetAttribute(ATTR_SLOT_FILLED) == true
			local slotFilled = padFilledAttr or (type(slotId) == "string" and filled[slotId] == true)
			if not slotFilled then
				-- Prefer the lowest slot id for a stable "first" choice.
				local slotKey = if type(slotId) == "string" then slotId else ""
				if best == nil or (bestSlot ~= nil and slotKey < bestSlot) then
					best = instance
					bestSlot = slotKey
				end
			end
		end
	end
	return best
end

-- True once the local player has at least one pet displayed on a podium.
local function hasDisplayedPet(): boolean
	local shelfUI = getController("ShelfUI")
	if type(shelfUI) == "table" and type(shelfUI.GetKnownShelf) == "function" then
		local ok, slots = pcall(shelfUI.GetKnownShelf, LocalPlayer.UserId)
		if ok and type(slots) == "table" then
			for _, cryptlingId in slots :: { [any]: any } do
				if type(cryptlingId) == "string" then
					return true
				end
			end
		end
	end
	return false
end

--------------------------------------------------------------------------------
-- Equip detection (Pet.GetState equippedId)
--------------------------------------------------------------------------------

local function hasEquippedPet(): boolean
	local ok, state = pcall(function()
		return Remotes.GetFunction("Pet.GetState"):InvokeServer()
	end)
	if ok and type(state) == "table" and type(state.equippedId) == "string" and state.equippedId ~= "" then
		return true
	end
	return false
end

--------------------------------------------------------------------------------
-- Clock-in zone discovery (factory queue pad)
--------------------------------------------------------------------------------

local function findClockInZone(): BasePart?
	local hub = Workspace:FindFirstChild(HUB_MODEL_NAME)
	local pad = if hub ~= nil then hub:FindFirstChild(PAD_MODEL_NAME) else nil
	local zone = if pad ~= nil then pad:FindFirstChild(CLOCK_IN_ZONE_NAME, true) else nil
	if zone ~= nil and zone:IsA("BasePart") then
		return zone
	end
	return nil
end

-- True when `point` is inside the clock-in zone part's oriented bounds (a small
-- vertical pad). Used so the guide tears down the moment the player ARRIVES — an
-- action gate, never a timer.
local ZONE_ARRIVAL_PADDING = 2 -- studs of slack so standing on the pad always counts

local function isInZone(point: Vector3, zone: BasePart): boolean
	local local_ = zone.CFrame:PointToObjectSpace(point)
	local half = zone.Size * 0.5
	return math.abs(local_.X) <= half.X + ZONE_ARRIVAL_PADDING
		and math.abs(local_.Y) <= half.Y + ZONE_ARRIVAL_PADDING
		and math.abs(local_.Z) <= half.Z + ZONE_ARRIVAL_PADDING
end

--------------------------------------------------------------------------------
-- Teardown
--------------------------------------------------------------------------------

function clearPodiumMarker()
	-- Disconnect the rotating-ring RenderStepped before destroying the host so the
	-- connection never references a destroyed part for a frame.
	if beaconRingConnection ~= nil then
		(beaconRingConnection :: RBXScriptConnection):Disconnect()
		beaconRingConnection = nil
	end
	-- A single host:Destroy() removes pillar / beam / highlight / ring / billboard.
	if beaconHost ~= nil then
		(beaconHost :: BasePart):Destroy()
		beaconHost = nil
	end
	if podiumMarkerPart ~= nil then
		(podiumMarkerPart :: BasePart):Destroy()
		podiumMarkerPart = nil
	end
end

local function clearClockInGuidance()
	clockInPosition = nil
	if arrowConnection ~= nil then
		(arrowConnection :: RBXScriptConnection):Disconnect()
		arrowConnection = nil
	end
	if arrowFrame ~= nil then
		(arrowFrame :: Frame).Visible = false
	end
	if clockInMarkerPart ~= nil then
		(clockInMarkerPart :: BasePart):Destroy()
		clockInMarkerPart = nil
	end
end

local function finish()
	running = false
	hideSubtitle()
	clearPetChipPulse()
	clearPodiumMarker()
	clearClockInGuidance()
end

--------------------------------------------------------------------------------
-- Detection waiter: resolves when `predicate()` is true, a one-shot signal
-- fires, or the failsafe elapses. Never yields the caller's thread visibly.
--------------------------------------------------------------------------------

-- Waits until predicate() returns true (polled), or the failsafe elapses.
-- Returns true if the predicate was satisfied, false on failsafe.
local function waitUntil(predicate: () -> boolean, failsafeSeconds: number): boolean
	local deadline = os.clock() + failsafeSeconds
	while running and os.clock() < deadline do
		local ok, result = pcall(predicate)
		if ok and result == true then
			return true
		end
		task.wait(DETECT_POLL_SECONDS)
	end
	return false
end

--------------------------------------------------------------------------------
-- The step machine (each step = ONE simple kid instruction)
--------------------------------------------------------------------------------

-- Step 2 detection: the unbox flow. We watch LockerChanged for the case count
-- dropping (the free case is opened) OR a non-empty pet collection appearing.
local lockerCaseBaseline: number? = nil
local lockerCaseOpened = false

local function onLockerChanged(payload: any)
	if not running then
		return
	end
	if type(payload) ~= "table" or type(payload.cases) ~= "table" then
		return
	end
	local count = #payload.cases
	if lockerCaseBaseline == nil then
		lockerCaseBaseline = count
		return
	end
	if count < (lockerCaseBaseline :: number) then
		lockerCaseOpened = true
	end
	lockerCaseBaseline = count
end

-- Live locker case count from the server (guarded). Used to SEED the baseline at
-- the start of the open step: the grant's LockerChanged fires before the guide is
-- running (onLockerChanged early-returns when not running), so without this seed
-- the first change we see is the open itself (count -> 0) and the nil-baseline
-- branch would swallow it, stranding the player on "Tap your free box".
local function currentLockerCaseCount(): number?
	local ok, state = pcall(function()
		return Remotes.GetFunction("GetLockerState"):InvokeServer()
	end)
	if ok and type(state) == "table" and type(state.cases) == "table" then
		return #state.cases
	end
	return nil
end

-- One-shot final teardown of ALL starter-guide FX at clock-in arrival. Driven by
-- the ARRIVAL action (HRP inside the zone) OR the in-shift OnboardingBeat "ClockIn"
-- (the foreman taking over) — NEVER by a timer. Idempotent: only the first caller
-- runs it, so the arrival watcher, the beat handler, and the cosmetic backstop can
-- all race safely.
local function onClockInArrived()
	if not clockInArrivalActive then
		return
	end
	clockInArrivalActive = false
	clearClockInGuidance()
	hideSubtitle()
	finish() -- hands off: the in-shift OnboardingBeat foreman flow takes over.
end

local function runStepMachine()
	-- STEP 1 + 2: open the locker, then guide the player to open their free box.
	openLocker()
	showSubtitle(GameConstants.STARTER_GUIDE.OPEN_CASE)
	-- Seed the case-count baseline from the LIVE locker so the open is detected as
	-- a drop the instant it happens (the grant fired before the guide was running,
	-- so onLockerChanged never captured a baseline).
	local seededCount = currentLockerCaseCount()
	if seededCount ~= nil then
		lockerCaseBaseline = seededCount
	end
	-- ACTION GATE: a case is opened (LockerChanged count drop) or a pet is owned.
	waitUntil(function()
		return lockerCaseOpened or hasEquippedPet() or hasDisplayedPet()
	end, STEP_FAILSAFE_SECONDS)
	if not running then
		return
	end

	-- EFFECT (not a wait-gate): server-authoritative teleport to the player's lot.
	-- Fired only AFTER the case-opened action gate passed; the teleport is the
	-- reward for the action, never the driver of the next one.
	requestTeleport("StarterGuide.TeleportToLot")

	-- Friendly "you made it" arrival cue (cosmetic dwell only — never a
	-- progression gate; the next step still advances on the real place action).
	showSubtitle(GameConstants.STARTER_GUIDE.LOT_ARRIVAL)
	task.wait(1.4)
	if not running then
		return
	end

	-- STEP 3: PLACE on a podium. BIG AAA BEACON over the first empty OWNED pad.
	-- The pad streams in after the teleport, so retry (the openLocker bounded-retry
	-- idiom) until it resolves.
	clearPetChipPulse()
	showSubtitle(GameConstants.STARTER_GUIDE.PLACE_PODIUM)
	local pad: BasePart? = nil
	for _ = 1, OPEN_LOCKER_MAX_TRIES do
		pad = findFirstEmptyOwnPad()
		if pad ~= nil then
			break
		end
		task.wait(OPEN_LOCKER_RETRY_SECONDS)
		if not running then
			return
		end
	end
	if pad ~= nil then
		buildPodiumBeacon(pad)
	end
	-- ACTION GATE: a pet is actually displayed (ShelfChanged -> a slot fills).
	local placed = waitUntil(hasDisplayedPet, STEP_FAILSAFE_SECONDS)
	if placed then
		playPodiumConfirm() -- satisfying confirm pop on a real placement.
	end
	clearPodiumMarker()
	if not running then
		return
	end

	-- STEP 4: EQUIP the pet. Pulse the PETS chip; ACTION GATE on Pet.GetState.
	showSubtitle(GameConstants.STARTER_GUIDE.EQUIP_PET)
	startPetChipPulse()
	local equipped = waitUntil(hasEquippedPet, STEP_FAILSAFE_SECONDS)
	clearPetChipPulse()
	if equipped then
		playPodiumConfirm() -- confirm pop at the player (the podium beacon is gone).
	end
	if not running then
		return
	end

	-- Transition cue, then the final server-authoritative teleport to clock-in
	-- (cosmetic dwell only — not a progression gate).
	showSubtitle(GameConstants.STARTER_GUIDE.CLOCK_IN)
	task.wait(1.2)
	if not running then
		return
	end

	-- EFFECT (not a wait-gate): fired only AFTER the equip action gate passed.
	requestTeleport("StarterGuide.TeleportToClockIn")

	-- STEP 5: CLOCK-IN arrival guidance. Edge arrow + billboard at the zone.
	showSubtitle(GameConstants.STARTER_GUIDE.CLOCK_ARRIVAL)
	clockInArrivalActive = true
	local zone = findClockInZone()
	if zone ~= nil then
		clockInPosition = zone.Position
		local markerHost = makeMarkerPart("StarterGuideClockInMarker", zone.Position + Vector3.new(0, 8, 0))
		makeBillboard(markerHost, GameConstants.STARTER_GUIDE.CLOCK_IN_MARKER, COLOR_MARKER)
		clockInMarkerPart = markerHost
		local screenGui = ensureGui()
		if arrowFrame == nil or (arrowFrame :: Frame).Parent == nil then
			arrowFrame = buildArrowFrame(screenGui)
		end
		arrowConnection = RunService.RenderStepped:Connect(updateClockInArrow)
	end

	-- STEP 6: tear down on ARRIVAL (HRP inside the zone) — an action gate, NOT a
	-- timer. The OnboardingBeat "ClockIn" handler (Start) also triggers the same
	-- teardown. CLOCK_IN_MARKER_SECONDS stays ONLY as the cosmetic anti-softlock
	-- backstop so missed guidance can never linger; it never advances any step.
	task.spawn(function()
		waitUntil(function()
			if zone == nil then
				return false
			end
			local character = LocalPlayer.Character
			local hrp = character and character:FindFirstChild("HumanoidRootPart")
			return hrp ~= nil and hrp:IsA("BasePart") and isInZone((hrp :: BasePart).Position, zone)
		end, CLOCK_IN_MARKER_SECONDS)
		onClockInArrived()
	end)
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- Kicks off the guided sequence. Called by WelcomeController when the player
-- taps GOT IT. One-shot per session; safe to call again (no-op while running).
function StarterGuideController.Begin()
	if started or running then
		return
	end
	started = true
	running = true
	lockerCaseBaseline = nil
	lockerCaseOpened = false
	task.spawn(runStepMachine)
end

--------------------------------------------------------------------------------
-- Lifecycle (loader contract: Init no yields, Start spawned)
--------------------------------------------------------------------------------

function StarterGuideController:Init(registry: any)
	-- NOTE: the loader's :Start lifecycle hook is below; the PUBLIC guide kickoff
	-- is StarterGuideController.Begin(), called by WelcomeController. They are
	-- intentionally distinct so the loader never auto-launches the guide.
	registryRef = registry
end

function StarterGuideController:Start()
	-- Watch LockerChanged for the "case opened" detection signal. Connecting
	-- here (Remotes.Get yields on the client) keeps the public Start() snappy.
	Remotes.GetEvent("LockerChanged").OnClientEvent:Connect(onLockerChanged)

	-- Additive clock-in teardown trigger: when the in-shift foreman flow fires its
	-- "ClockIn" beat, tear down the final starter guidance and hand off. This is an
	-- ACTION signal (the player clocked in), not a timer; it races safely with the
	-- arrival watcher because onClockInArrived is one-shot.
	Remotes.GetEvent("OnboardingBeat").OnClientEvent:Connect(function(payload: any)
		if type(payload) == "table" and payload.beat == "ClockIn" then
			onClockInArrived()
		end
	end)
end

return StarterGuideController
