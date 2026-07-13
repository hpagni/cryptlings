--!strict
-- CRYPTLINGS: NIGHT SHIFT — IntroFloorController (R9, Lane intro-guide-ui).
-- The on-screen guide for the brand-new player's INTRO FLOOR: a short, scripted
-- "grab a box, then run from the thing, then escape the green door" moment that
-- teaches grab + run before the real shift. This controller is PURE CLIENT GUIDE:
-- the intro-runner SERVICE owns the floor, the boxes, the chaser and the gate
-- logic, and drives this UI ONLY through the owner-only "IntroBeat" remote. We
-- never decide progression here — we render one simple idea per beat.
--
-- AUDIENCE = KIDS: every prompt is THREE channels so a pre-reader still gets it:
--   text (short subtitle) + an icon/arrow (where to look) + a sound (a cue).
-- Copy of record is GameConstants.INTRO (kid-simple, no jargon, no em-dashes).
--
-- Beats (IntroBeat client step contract):
--   "enter"          -> GRAB_FIRST + bouncing arrow over the nearest glowing box
--                       + a tall gold/green "north-star" beacon over the exit.
--   "grabbed" {got,needed} -> if got<needed: GRAB_MORE + retarget arrow; juice.
--   "chaseTelegraph" -> CHASE_TELEGRAPH + red screen-edge vignette + rumble +
--                       a brief shake (skipped if ReducedMotionEnabled).
--   "chaseStart"     -> RUN_TO_EXIT + brighten beacon + big arrow over the exit;
--                       adaptive STUCK_HINT if the player stops moving.
--   "reachExit"      -> REACHED_EXIT + triumphant sting + light burst.
--   "done"           -> clear ALL intro UI; restore Camera.CameraType = Custom.
--
-- The remote yields on Get, so we connect in :Start() (never :Init()). All
-- visuals are ScreenGui / BillboardGui / Beam / Neon only — the lobby has a
-- 50-light equality pin, so this controller NEVER creates a Light instance.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")
local GuiService = game:GetService("GuiService")
local CollectionService = game:GetService("CollectionService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConstants = require(Shared:WaitForChild("Config"):WaitForChild("GameConstants"))
local Remotes = require(Shared:WaitForChild("Net"):WaitForChild("Remotes"))

local LocalPlayer = Players.LocalPlayer

--------------------------------------------------------------------------------
-- World discovery contracts (best-effort; the guide degrades gracefully when a
-- target is not yet streamed in — the subtitle still carries the step).
--------------------------------------------------------------------------------

-- Intro boxes are CaseService.SpawnCaseAt spawns: Models tagged "Case" with a
-- "CaseUid" attribute and a "Body" part. We pick the nearest one to the player.
local TAG_CASE = "Case"

-- The exit "green door". The intro-runner/world lane owns it; we find it by tag
-- first, then by a name fallback, then give up gracefully (subtitle carries it).
local TAG_INTRO_EXIT = "IntroExit"
local EXIT_NAME_HINTS = { "IntroExit", "IntroFloorExit", "WayOut", "ExitDoor" }

--------------------------------------------------------------------------------
-- Tuning (cosmetic, this module's domain) — mirrors StarterGuideController.
--------------------------------------------------------------------------------

local TYPEWRITER_CHARS_PER_SECOND = 28
local BLIP_EVERY_GRAPHEMES = 2
local BLIP_SOUND_ID = "rbxasset://sounds/electronicpingshort.wav"
local BLIP_VOLUME = 0.22

local DESIGN_SHORT_AXIS_PX = 450
local UISCALE_MIN = 0.85
local UISCALE_MAX = 1.6

local DISPLAY_ORDER = 23 -- above the HUD, peer to the StarterGuide guide layer

-- Three-channel cue sounds (kid-readable: every prompt pairs with a sound).
local SOUND_GRAB = "rbxasset://sounds/electronicpingshort.wav" -- sparkle/chime on grab
local SOUND_TELEGRAPH = "rbxasset://sounds/impact_water.mp3" -- low "uh oh" rumble
local SOUND_WIN = "rbxasset://sounds/victory.mid" -- triumphant sting on reach exit

local COLOR_PANEL = Color3.fromRGB(18, 20, 24)
local COLOR_ACCENT = Color3.fromRGB(120, 230, 140) -- friendly guidance green
local COLOR_MARKER = Color3.fromRGB(255, 224, 130) -- warm gold
local COLOR_EXIT = Color3.fromRGB(90, 235, 130) -- the green door / north-star
local COLOR_DANGER = Color3.fromRGB(235, 70, 70) -- chase vignette red

-- Exit beacon geometry (Neon + Beam only; NO Light).
local BEACON_PILLAR_SIZE = Vector3.new(3, 80, 3)
local BEACON_PILLAR_HEIGHT = 40
local BEACON_TOP_OFFSET = 78

-- Box arrow bounce + size.
local ARROW_BILLBOARD_SIZE = UDim2.fromOffset(70, 70)
local ARROW_BOUNCE_STUDS = 1.6

-- Adaptive stuck detection while running to the exit.
local STUCK_POLL_SECONDS = 0.4
local STUCK_MOVE_EPSILON = 6 -- studs; movement under this over the window = stuck

-- Brief camera shake on the telegraph.
local SHAKE_SECONDS = 0.5
local SHAKE_MAGNITUDE = 1.2

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local IntroFloorController = {}

local started = false

local gui: ScreenGui? = nil
local subtitleFrame: Frame? = nil
local subtitleLabel: TextLabel? = nil
local blipSound: Sound? = nil
local typeToken = 0

local vignetteFrame: Frame? = nil
local vignetteTween: Tween? = nil

local fxFolder: Folder? = nil

-- Exit "north-star" beacon: one host part with all beacon children, plus the
-- screen-edge arrow that points at it while it is off-screen.
local exitBeaconHost: BasePart? = nil
local exitPillar: BasePart? = nil
local exitBeam: Beam? = nil
local exitArrowGui: BillboardGui? = nil

-- Box arrow (bouncing BillboardGui over the target box).
local boxArrowGui: BillboardGui? = nil
local boxArrowBounce: RBXScriptConnection? = nil

-- Stuck watcher (only live during the chase run).
local stuckConnection: RBXScriptConnection? = nil
local stuckActive = false

-- Box-arrow watcher (live during the grab phase). Keeps an arrow on the nearest
-- glowing box even as boxes stream in late and as the kid collects them.
local boxArrowConnection: RBXScriptConnection? = nil
local boxArrowActive = false

-- Camera scriptable guard (only if we ever set Scriptable; we re-assert it to
-- dodge the Scriptable->Custom override bug, and ALWAYS restore on done/cleanup).
local cameraScripted = false
local cameraGuardConnection: RBXScriptConnection? = nil
local cameraCharacterConnection: RBXScriptConnection? = nil
local shakeConnection: RBXScriptConnection? = nil

--------------------------------------------------------------------------------
-- Accessibility helpers (respect the player's reduced-motion / text prefs)
--------------------------------------------------------------------------------

local function reducedMotion(): boolean
	local ok, value = pcall(function()
		return GuiService.ReducedMotionEnabled
	end)
	return ok and value == true
end

local function preferredTransparency(): number
	local ok, value = pcall(function()
		return GuiService.PreferredTransparency
	end)
	if ok and type(value) == "number" then
		return math.clamp(value, 0, 1)
	end
	return 1
end

-- Bumps a base text size by the player's accessibility preference, when set.
local function scaledTextSize(base: number): number
	local ok, value = pcall(function()
		return GuiService.PreferredTextSize
	end)
	if ok and typeof(value) == "EnumItem" then
		if value == Enum.PreferredTextSize.Large then
			return base + 4
		elseif value == Enum.PreferredTextSize.Larger then
			return base + 8
		end
	end
	return base
end

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
	screenGui.Name = "IntroFloorGui"
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = true
	screenGui.DisplayOrder = DISPLAY_ORDER

	local scale = Instance.new("UIScale")
	scale.Parent = screenGui
	applyUiScale(scale)
	local camera = Workspace.CurrentCamera
	if camera ~= nil then
		camera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
			applyUiScale(scale)
		end)
	end

	-- Red screen-edge vignette (chase telegraph). One border-only frame using a
	-- thick UIStroke so the center stays clear; pulsed on, faded with the chase.
	local vignette = Instance.new("Frame")
	vignette.Name = "ChaseVignette"
	vignette.Size = UDim2.fromScale(1, 1)
	vignette.BackgroundTransparency = 1
	vignette.BorderSizePixel = 0
	vignette.Visible = false
	vignette.ZIndex = 1
	vignette.Parent = screenGui

	local vignetteStroke = Instance.new("UIStroke")
	vignetteStroke.Name = "Edge"
	vignetteStroke.Color = COLOR_DANGER
	vignetteStroke.Thickness = 28
	vignetteStroke.Transparency = 0.2
	vignetteStroke.Parent = vignette

	-- Bottom-third subtitle bar (matches StarterGuideController's passive style).
	local bar = Instance.new("Frame")
	bar.Name = "SubtitleBar"
	bar.AnchorPoint = Vector2.new(0.5, 1)
	bar.Position = UDim2.fromScale(0.5, 0.84)
	bar.Size = UDim2.fromScale(0.86, 0)
	bar.AutomaticSize = Enum.AutomaticSize.Y
	bar.BackgroundColor3 = COLOR_PANEL
	bar.BackgroundTransparency = math.max(0.2, 1 - preferredTransparency())
	bar.BorderSizePixel = 0
	bar.Visible = false
	bar.ZIndex = 2
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
	text.TextSize = scaledTextSize(22)
	text.TextColor3 = COLOR_ACCENT
	text.TextWrapped = true
	text.TextXAlignment = Enum.TextXAlignment.Center
	text.TextYAlignment = Enum.TextYAlignment.Center
	text.Text = ""
	text.ZIndex = 2
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
	vignetteFrame = vignette
	return screenGui
end

local function ensureFxFolder(): Folder
	local existing = fxFolder
	if existing ~= nil and existing.Parent ~= nil then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = "IntroFloorClientFX"
	folder.Parent = Workspace
	fxFolder = folder
	return folder
end

-- One-shot cue sound parented under the gui (cleaned up on its own lifetime).
local function playCue(soundId: string, volume: number)
	local screenGui = ensureGui()
	local sound = Instance.new("Sound")
	sound.Name = "IntroCue"
	sound.SoundId = soundId
	sound.Volume = volume
	sound.Parent = screenGui
	sound.Ended:Connect(function()
		sound:Destroy()
	end)
	local ok = pcall(function()
		sound:Play()
	end)
	if not ok then
		sound:Destroy()
	end
	-- Hard backstop so a non-loading id never leaks.
	task.delay(6, function()
		if sound.Parent ~= nil then
			sound:Destroy()
		end
	end)
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
	bar.Visible = true

	if reducedMotion() then
		-- No typewriter animation when reduced motion is on: show it all at once.
		label.MaxVisibleGraphemes = -1
		return
	end

	label.MaxVisibleGraphemes = 0
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
-- Player / target helpers
--------------------------------------------------------------------------------

local function getHrp(): BasePart?
	local character = LocalPlayer.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if hrp ~= nil and hrp:IsA("BasePart") then
		return hrp :: BasePart
	end
	return nil
end

-- The case Model's adornable part (Body) for a billboard, or the model itself.
local function caseAdornee(model: Model): Instance
	local body = model:FindFirstChild("Body")
	if body ~= nil and body:IsA("BasePart") then
		return body
	end
	local primary = model.PrimaryPart
	if primary ~= nil then
		return primary
	end
	return model
end

local function caseWorldPosition(model: Model): Vector3?
	local adornee = caseAdornee(model)
	if adornee:IsA("BasePart") then
		return (adornee :: BasePart).Position
	end
	local ok, cframe = pcall(function()
		return model:GetPivot()
	end)
	if ok then
		return cframe.Position
	end
	return nil
end

-- A box is "carried" once it is parented under a character (a Model with a
-- Humanoid) — skip those so the arrow never points at a box already on the kid.
local function isBoxCarried(model: Model): boolean
	local ancestor: Instance? = model.Parent
	while ancestor ~= nil do
		if ancestor:IsA("Model") and ancestor:FindFirstChildOfClass("Humanoid") ~= nil then
			return true
		end
		ancestor = ancestor.Parent
	end
	return false
end

-- The nearest glowing intro box (Case-tagged model) to the player. Falls back to
-- nil when none are streamed in (the subtitle still carries the step).
local function findNearestBox(): Model?
	local hrp = getHrp()
	local origin = if hrp ~= nil then hrp.Position else nil
	local best: Model? = nil
	local bestDist = math.huge
	for _, instance in CollectionService:GetTagged(TAG_CASE) do
		if instance:IsA("Model") and instance:GetAttribute("CaseUid") ~= nil and not isBoxCarried(instance :: Model) then
			local position = caseWorldPosition(instance :: Model)
			if position ~= nil then
				if origin == nil then
					return instance :: Model
				end
				local dist = (position - origin).Magnitude
				if dist < bestDist then
					bestDist = dist
					best = instance :: Model
				end
			end
		end
	end
	return best
end

-- The exit "green door" part. Tag first, then a name-hint search, else nil.
local function findExitPart(): BasePart?
	for _, instance in CollectionService:GetTagged(TAG_INTRO_EXIT) do
		if instance:IsA("BasePart") then
			return instance :: BasePart
		end
		if instance:IsA("Model") then
			local primary = (instance :: Model).PrimaryPart
			if primary ~= nil then
				return primary
			end
		end
	end
	for _, hint in EXIT_NAME_HINTS do
		local found = Workspace:FindFirstChild(hint, true)
		if found ~= nil then
			if found:IsA("BasePart") then
				return found :: BasePart
			end
			if found:IsA("Model") and (found :: Model).PrimaryPart ~= nil then
				return (found :: Model).PrimaryPart
			end
			local anyPart = found:FindFirstChildWhichIsA("BasePart", true)
			if anyPart ~= nil then
				return anyPart
			end
		end
	end
	return nil
end

--------------------------------------------------------------------------------
-- Bouncing arrow over a box (BillboardGui, AlwaysOnTop)
--------------------------------------------------------------------------------

local function clearBoxArrow()
	if boxArrowBounce ~= nil then
		(boxArrowBounce :: RBXScriptConnection):Disconnect()
		boxArrowBounce = nil
	end
	if boxArrowGui ~= nil then
		(boxArrowGui :: BillboardGui):Destroy()
		boxArrowGui = nil
	end
end

-- Builds (or retargets) the bouncing down-arrow + "GRAB!" tag over `model`.
local function pointArrowAtBox(model: Model)
	clearBoxArrow()
	local adornee = caseAdornee(model)

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "IntroBoxArrow"
	billboard.Adornee = adornee
	billboard.Size = ARROW_BILLBOARD_SIZE
	billboard.StudsOffset = Vector3.new(0, 4.5, 0)
	billboard.AlwaysOnTop = true
	billboard.MaxDistance = 600

	-- A simple down-pointing chevron from two rotated bars (no image assets).
	local arrow = Instance.new("Frame")
	arrow.Name = "Chevron"
	arrow.AnchorPoint = Vector2.new(0.5, 0.5)
	arrow.Position = UDim2.fromScale(0.5, 0.55)
	arrow.Size = UDim2.fromOffset(48, 48)
	arrow.BackgroundTransparency = 1
	arrow.Parent = billboard

	local barLeft = Instance.new("Frame")
	barLeft.Name = "BarLeft"
	barLeft.AnchorPoint = Vector2.new(0.5, 0.5)
	barLeft.Position = UDim2.fromScale(0.36, 0.5)
	barLeft.Size = UDim2.fromOffset(30, 8)
	barLeft.Rotation = -45
	barLeft.BackgroundColor3 = COLOR_MARKER
	barLeft.BorderSizePixel = 0
	barLeft.Parent = arrow
	local barLeftCorner = Instance.new("UICorner")
	barLeftCorner.CornerRadius = UDim.new(1, 0)
	barLeftCorner.Parent = barLeft

	local barRight = barLeft:Clone()
	barRight.Name = "BarRight"
	barRight.Position = UDim2.fromScale(0.64, 0.5)
	barRight.Rotation = 45
	barRight.Parent = arrow

	-- "GRAB!" tag under the chevron (the third readable channel).
	local tag = Instance.new("TextLabel")
	tag.Name = "GrabTag"
	tag.AnchorPoint = Vector2.new(0.5, 0)
	tag.Position = UDim2.fromScale(0.5, 0.62)
	tag.Size = UDim2.fromOffset(70, 22)
	tag.BackgroundColor3 = COLOR_PANEL
	tag.BackgroundTransparency = 0.25
	tag.Font = Enum.Font.GothamBold
	tag.TextSize = scaledTextSize(16)
	tag.TextColor3 = COLOR_MARKER
	tag.Text = GameConstants.INTRO.BOX_MARKER
	tag.Parent = billboard
	local tagCorner = Instance.new("UICorner")
	tagCorner.CornerRadius = UDim.new(0, 8)
	tagCorner.Parent = tag

	billboard.Parent = adornee
	boxArrowGui = billboard

	-- Gentle bounce so the arrow reads as "tap me" (skipped on reduced motion).
	if not reducedMotion() then
		local baseY = billboard.StudsOffset.Y
		local phase = 0
		boxArrowBounce = RunService.RenderStepped:Connect(function(dt: number)
			if billboard.Parent == nil then
				return
			end
			phase += dt * 4
			billboard.StudsOffset = Vector3.new(0, baseY + math.sin(phase) * ARROW_BOUNCE_STUDS, 0)
		end)
	end
end

-- Sparkle pop at the box (juice on a successful grab; cosmetic, self-cleaning).
local function sparkleAt(position: Vector3)
	if reducedMotion() then
		return
	end
	local pop = Instance.new("Part")
	pop.Name = "IntroSparkle"
	pop.Shape = Enum.PartType.Ball
	pop.Size = Vector3.new(2, 2, 2)
	pop.Position = position + Vector3.new(0, 2, 0)
	pop.Anchored = true
	pop.CanCollide = false
	pop.CanQuery = false
	pop.CanTouch = false
	pop.Material = Enum.Material.Neon
	pop.Color = COLOR_MARKER
	pop.Transparency = 0.1
	pop.Parent = ensureFxFolder()
	local grow = TweenService:Create(
		pop,
		TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = Vector3.new(7, 7, 7), Transparency = 1 }
	)
	grow.Completed:Connect(function()
		pop:Destroy()
	end)
	grow:Play()
end

--------------------------------------------------------------------------------
-- Exit "north-star" beacon (Neon pillar + Beam shaft + off-screen edge arrow).
-- NO Light instances (lobby 50-light pin) — Neon + Beam only.
--------------------------------------------------------------------------------

local function clearExitBeacon()
	if exitArrowGui ~= nil then
		(exitArrowGui :: BillboardGui):Destroy()
		exitArrowGui = nil
	end
	if exitBeaconHost ~= nil then
		(exitBeaconHost :: BasePart):Destroy()
		exitBeaconHost = nil
	end
	exitPillar = nil
	exitBeam = nil
end

local function buildExitBeacon()
	local exit = findExitPart()
	if exit == nil then
		return -- not streamed in yet; the subtitle still carries the step
	end
	clearExitBeacon()

	local host = Instance.new("Part")
	host.Name = "IntroExitBeacon"
	host.Size = Vector3.one
	host.Position = exit.Position
	host.Anchored = true
	host.CanCollide = false
	host.CanQuery = false
	host.CanTouch = false
	host.Transparency = 1
	host.Parent = ensureFxFolder()

	-- Tall Neon pillar (the "north star"), gentle transparency breathing.
	local pillar = Instance.new("Part")
	pillar.Name = "Pillar"
	pillar.Size = BEACON_PILLAR_SIZE
	pillar.Position = exit.Position + Vector3.new(0, BEACON_PILLAR_HEIGHT, 0)
	pillar.Anchored = true
	pillar.CanCollide = false
	pillar.CanQuery = false
	pillar.CanTouch = false
	pillar.Material = Enum.Material.Neon
	pillar.Color = COLOR_EXIT
	pillar.Transparency = 0.45
	pillar.Parent = host
	if not reducedMotion() then
		TweenService:Create(
			pillar,
			TweenInfo.new(0.9, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
			{ Transparency = 0.8 }
		):Play()
	end

	-- Beam shaft (bright FaceCamera column from the door up).
	local baseAttachment = Instance.new("Attachment")
	baseAttachment.Name = "BeaconBase"
	baseAttachment.WorldPosition = exit.Position + Vector3.new(0, 1, 0)
	baseAttachment.Parent = host
	local topAttachment = Instance.new("Attachment")
	topAttachment.Name = "BeaconTop"
	topAttachment.WorldPosition = exit.Position + Vector3.new(0, BEACON_TOP_OFFSET, 0)
	topAttachment.Parent = host
	local beam = Instance.new("Beam")
	beam.Name = "Shaft"
	beam.Attachment0 = baseAttachment
	beam.Attachment1 = topAttachment
	beam.Color = ColorSequence.new(COLOR_EXIT)
	beam.LightEmission = 1
	beam.FaceCamera = true
	beam.Width0 = 7
	beam.Width1 = 2
	beam.Transparency = NumberSequence.new(0.15)
	beam.Parent = host

	-- A friendly "WAY OUT" billboard floated near the top of the door.
	local label = Instance.new("BillboardGui")
	label.Name = "ExitLabel"
	label.Adornee = host
	label.Size = UDim2.fromOffset(150, 44)
	label.StudsOffset = Vector3.new(0, 6, 0)
	label.AlwaysOnTop = true
	label.MaxDistance = 1000
	local labelText = Instance.new("TextLabel")
	labelText.Name = "MarkerText"
	labelText.BackgroundColor3 = COLOR_PANEL
	labelText.BackgroundTransparency = 0.25
	labelText.Size = UDim2.fromScale(1, 1)
	labelText.Font = Enum.Font.GothamBold
	labelText.TextSize = scaledTextSize(18)
	labelText.TextColor3 = COLOR_EXIT
	labelText.Text = GameConstants.INTRO.EXIT_MARKER
	labelText.Parent = label
	local labelCorner = Instance.new("UICorner")
	labelCorner.CornerRadius = UDim.new(0, 10)
	labelCorner.Parent = labelText
	label.Parent = host

	exitBeaconHost = host
	exitPillar = pillar
	exitBeam = beam
end

-- Brighten the beacon (chaseStart) — wider, less transparent, optional big arrow.
local function brightenExitBeacon()
	local pillar = exitPillar
	if pillar ~= nil then
		pillar.Color = COLOR_EXIT
		pillar.Transparency = 0.2
		pillar.Size = BEACON_PILLAR_SIZE + Vector3.new(2, 0, 2)
	end
	local beam = exitBeam
	if beam ~= nil then
		beam.Width0 = 10
		beam.Width1 = 3
		beam.Transparency = NumberSequence.new(0.05)
	end

	-- A big bouncing down-arrow over the exit so the "run here" target is loud.
	local host = exitBeaconHost
	if host ~= nil and exitArrowGui == nil then
		local billboard = Instance.new("BillboardGui")
		billboard.Name = "ExitArrow"
		billboard.Adornee = host
		billboard.Size = UDim2.fromOffset(90, 90)
		billboard.StudsOffset = Vector3.new(0, 11, 0)
		billboard.AlwaysOnTop = true
		billboard.MaxDistance = 1000

		local arrow = Instance.new("Frame")
		arrow.AnchorPoint = Vector2.new(0.5, 0.5)
		arrow.Position = UDim2.fromScale(0.5, 0.5)
		arrow.Size = UDim2.fromOffset(70, 70)
		arrow.BackgroundTransparency = 1
		arrow.Parent = billboard

		local barLeft = Instance.new("Frame")
		barLeft.AnchorPoint = Vector2.new(0.5, 0.5)
		barLeft.Position = UDim2.fromScale(0.36, 0.5)
		barLeft.Size = UDim2.fromOffset(42, 11)
		barLeft.Rotation = -45
		barLeft.BackgroundColor3 = COLOR_EXIT
		barLeft.BorderSizePixel = 0
		barLeft.Parent = arrow
		local barLeftCorner = Instance.new("UICorner")
		barLeftCorner.CornerRadius = UDim.new(1, 0)
		barLeftCorner.Parent = barLeft

		local barRight = barLeft:Clone()
		barRight.Position = UDim2.fromScale(0.64, 0.5)
		barRight.Rotation = 45
		barRight.Parent = arrow

		billboard.Parent = host
		exitArrowGui = billboard
	end
end

-- Adaptive escalation when the player is stuck: grow the arrow + brighten more.
local function escalateExitBeacon()
	local pillar = exitPillar
	if pillar ~= nil then
		pillar.Transparency = 0.1
		pillar.Size = BEACON_PILLAR_SIZE + Vector3.new(4, 0, 4)
	end
	local billboard = exitArrowGui
	if billboard ~= nil then
		billboard.Size = UDim2.fromOffset(130, 130)
	end
end

--------------------------------------------------------------------------------
-- Chase telegraph (red vignette + rumble + brief camera shake)
--------------------------------------------------------------------------------

local function showVignette()
	ensureGui()
	local vignette = vignetteFrame
	if vignette == nil then
		return
	end
	vignette.Visible = true
	local stroke = vignette:FindFirstChildOfClass("UIStroke")
	if stroke == nil then
		return
	end
	if vignetteTween ~= nil then
		(vignetteTween :: Tween):Cancel()
		vignetteTween = nil
	end
	if reducedMotion() then
		stroke.Transparency = 0.35
		return
	end
	stroke.Transparency = 0.85
	local pulse = TweenService:Create(
		stroke,
		TweenInfo.new(0.55, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ Transparency = 0.2 }
	)
	pulse:Play()
	vignetteTween = pulse
end

local function hideVignette()
	if vignetteTween ~= nil then
		(vignetteTween :: Tween):Cancel()
		vignetteTween = nil
	end
	local vignette = vignetteFrame
	if vignette ~= nil then
		(vignette :: Frame).Visible = false
	end
end

-- A brief, self-terminating camera shake (skipped when reduced motion is on).
-- Uses a transient scriptable camera so we never set a CFrame on a part; we
-- ALWAYS restore Custom afterward. Re-asserts Scriptable each frame during the
-- shake window to dodge the Scriptable->Custom override bug.
local function briefCameraShake()
	if reducedMotion() then
		return
	end
	local camera = Workspace.CurrentCamera
	if camera == nil then
		return
	end
	if shakeConnection ~= nil then
		return -- a shake is already running
	end
	local restType = camera.CameraType
	local elapsed = 0
	shakeConnection = RunService.RenderStepped:Connect(function(dt: number)
		local cam = Workspace.CurrentCamera
		if cam == nil then
			return
		end
		elapsed += dt
		if elapsed >= SHAKE_SECONDS then
			if shakeConnection ~= nil then
				(shakeConnection :: RBXScriptConnection):Disconnect()
				shakeConnection = nil
			end
			-- Restore whatever the camera was (Custom unless we drove Scriptable).
			cam.CameraType = if cameraScripted then Enum.CameraType.Scriptable else Enum.CameraType.Custom
			return
		end
		local falloff = 1 - (elapsed / SHAKE_SECONDS)
		local jitter = Vector3.new(
			(math.random() - 0.5) * 2,
			(math.random() - 0.5) * 2,
			(math.random() - 0.5) * 2
		) * SHAKE_MAGNITUDE * falloff
		cam.CameraType = Enum.CameraType.Scriptable
		cam.CFrame = cam.CFrame + jitter
	end)
	-- Best-effort restore if the connection somehow outlives the window.
	task.delay(SHAKE_SECONDS + 0.2, function()
		if shakeConnection ~= nil then
			(shakeConnection :: RBXScriptConnection):Disconnect()
			shakeConnection = nil
		end
		local cam = Workspace.CurrentCamera
		if cam ~= nil and not cameraScripted then
			cam.CameraType = if restType == Enum.CameraType.Scriptable
				then Enum.CameraType.Custom
				else restType
		end
	end)
end

-- Haptic rumble (mobile/gamepad). Best-effort; no-op where unsupported.
local function rumble()
	if reducedMotion() then
		return
	end
	pcall(function()
		local HapticService = game:GetService("HapticService")
		HapticService:SetMotor(Enum.UserInputType.Gamepad1, Enum.VibrationMotor.Large, 0.6)
		task.delay(0.4, function()
			pcall(function()
				HapticService:SetMotor(Enum.UserInputType.Gamepad1, Enum.VibrationMotor.Large, 0)
			end)
		end)
	end)
end

--------------------------------------------------------------------------------
-- Reach-exit light burst (Neon ball pop; cosmetic, self-cleaning)
--------------------------------------------------------------------------------

local function exitBurst()
	if reducedMotion() then
		return
	end
	local host = exitBeaconHost
	local exit = if host ~= nil then host else nil
	local position: Vector3? = if exit ~= nil then exit.Position else nil
	if position == nil then
		local found = findExitPart()
		position = if found ~= nil then found.Position else nil
	end
	if position == nil then
		local hrp = getHrp()
		position = if hrp ~= nil then hrp.Position else nil
	end
	if position == nil then
		return
	end
	local pop = Instance.new("Part")
	pop.Name = "IntroExitBurst"
	pop.Shape = Enum.PartType.Ball
	pop.Size = Vector3.new(3, 3, 3)
	pop.Position = position + Vector3.new(0, 3, 0)
	pop.Anchored = true
	pop.CanCollide = false
	pop.CanQuery = false
	pop.CanTouch = false
	pop.Material = Enum.Material.Neon
	pop.Color = COLOR_EXIT
	pop.Transparency = 0
	pop.Parent = ensureFxFolder()
	local grow = TweenService:Create(
		pop,
		TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = Vector3.new(16, 16, 16), Transparency = 1 }
	)
	grow.Completed:Connect(function()
		pop:Destroy()
	end)
	grow:Play()
end

--------------------------------------------------------------------------------
-- Adaptive stuck watcher (only live during the chase run)
--------------------------------------------------------------------------------

local function stopStuckWatcher()
	stuckActive = false
	if stuckConnection ~= nil then
		(stuckConnection :: RBXScriptConnection):Disconnect()
		stuckConnection = nil
	end
end

local function startStuckWatcher()
	stopStuckWatcher()
	stuckActive = true
	local accum = 0
	local stillTime = 0
	local lastPosition: Vector3? = nil
	local escalated = false
	stuckConnection = RunService.Heartbeat:Connect(function(dt: number)
		if not stuckActive then
			return
		end
		accum += dt
		if accum < STUCK_POLL_SECONDS then
			return
		end
		accum = 0
		local hrp = getHrp()
		if hrp == nil then
			return
		end
		local position = hrp.Position
		if lastPosition == nil then
			lastPosition = position
			return
		end
		local moved = (position - (lastPosition :: Vector3)).Magnitude
		lastPosition = position
		if moved < STUCK_MOVE_EPSILON then
			stillTime += STUCK_POLL_SECONDS
		else
			stillTime = 0
			escalated = false
		end
		if stillTime >= GameConstants.INTRO.STUCK_HINT_SECONDS and not escalated then
			escalated = true
			showSubtitle(GameConstants.INTRO.STUCK_HINT)
			escalateExitBeacon()
		end
	end)
end

--------------------------------------------------------------------------------
-- Box-arrow watcher: keep an arrow on the nearest glowing box during the grab
-- phase. Robust to boxes streaming in AFTER the enter beat, and retargets as the
-- kid collects them. Stopped the moment the chase starts.
--------------------------------------------------------------------------------

local function stopBoxArrowWatcher()
	boxArrowActive = false
	if boxArrowConnection ~= nil then
		(boxArrowConnection :: RBXScriptConnection):Disconnect()
		boxArrowConnection = nil
	end
end

local function startBoxArrowWatcher()
	if boxArrowActive then
		return
	end
	boxArrowActive = true
	local accum = 0
	local POLL = 0.35
	boxArrowConnection = RunService.Heartbeat:Connect(function(dt: number)
		if not boxArrowActive then
			return
		end
		accum += dt
		if accum < POLL then
			return
		end
		accum = 0
		local box = findNearestBox()
		if box ~= nil then
			pointArrowAtBox(box)
		else
			clearBoxArrow()
		end
	end)
end

--------------------------------------------------------------------------------
-- Camera restore (always called on done/cleanup)
--------------------------------------------------------------------------------

local function restoreCamera()
	if cameraGuardConnection ~= nil then
		(cameraGuardConnection :: RBXScriptConnection):Disconnect()
		cameraGuardConnection = nil
	end
	if cameraCharacterConnection ~= nil then
		(cameraCharacterConnection :: RBXScriptConnection):Disconnect()
		cameraCharacterConnection = nil
	end
	if shakeConnection ~= nil then
		(shakeConnection :: RBXScriptConnection):Disconnect()
		shakeConnection = nil
	end
	cameraScripted = false
	local camera = Workspace.CurrentCamera
	if camera ~= nil then
		camera.CameraType = Enum.CameraType.Custom
	end
end

--------------------------------------------------------------------------------
-- Full teardown (beat "done" and on any cleanup)
--------------------------------------------------------------------------------

local function clearAllIntroUi()
	hideSubtitle()
	hideVignette()
	stopBoxArrowWatcher()
	clearBoxArrow()
	clearExitBeacon()
	stopStuckWatcher()
	restoreCamera()
end

--------------------------------------------------------------------------------
-- Beat handlers (IntroBeat client step contract)
--------------------------------------------------------------------------------

local function onEnter()
	clearBoxArrow()
	showSubtitle(GameConstants.INTRO.GRAB_FIRST)
	-- A watcher (not a one-shot lookup) so the arrow appears as soon as the boxes
	-- stream in and follows the nearest one as the kid collects them.
	startBoxArrowWatcher()
	buildExitBeacon()
end

local function onGrabbed(data: any)
	local boxesGot = if type(data) == "table" and type(data.boxesGot) == "number" then data.boxesGot else 0
	local boxesNeeded = if type(data) == "table" and type(data.boxesNeeded) == "number"
		then data.boxesNeeded
		else GameConstants.INTRO.BOXES_NEEDED

	-- Sparkle + chime juice on the grab.
	local hrp = getHrp()
	if hrp ~= nil then
		sparkleAt(hrp.Position)
	end
	playCue(SOUND_GRAB, 0.5)

	if boxesGot < boxesNeeded then
		showSubtitle(GameConstants.INTRO.GRAB_MORE)
		local box = findNearestBox()
		if box ~= nil then
			pointArrowAtBox(box)
		else
			clearBoxArrow()
		end
	else
		-- Enough banked: drop the grab arrow; the run beat takes over next.
		clearBoxArrow()
	end
end

local function onChaseTelegraph()
	clearBoxArrow()
	showSubtitle(GameConstants.INTRO.CHASE_TELEGRAPH)
	showVignette()
	playCue(SOUND_TELEGRAPH, 0.5)
	rumble()
	briefCameraShake()
end

local function onChaseStart()
	stopBoxArrowWatcher()
	clearBoxArrow()
	showSubtitle(GameConstants.INTRO.RUN_TO_EXIT)
	if exitBeaconHost == nil then
		buildExitBeacon()
	end
	brightenExitBeacon()
	startStuckWatcher()
end

local function onReachExit()
	stopStuckWatcher()
	showSubtitle(GameConstants.INTRO.REACHED_EXIT)
	hideVignette()
	playCue(SOUND_WIN, 0.6)
	exitBurst()
end

-- Soft, non-lethal contact with the chaser: a quick encouraging nudge. The
-- server backs the chaser off, so this is reassurance, never punishment.
local function onBump()
	showSubtitle(GameConstants.INTRO.BUMP_NUDGE)
end

local function onDone()
	clearAllIntroUi()
end

--------------------------------------------------------------------------------
-- Remote dispatch
--------------------------------------------------------------------------------

local function onIntroBeat(payload: any)
	if type(payload) ~= "table" or type(payload.beat) ~= "string" then
		return
	end
	local beat = payload.beat
	local data = payload.data

	if beat == "enter" then
		onEnter()
	elseif beat == "grabbed" then
		onGrabbed(data)
	elseif beat == "chaseTelegraph" then
		onChaseTelegraph()
	elseif beat == "chaseStart" then
		onChaseStart()
	elseif beat == "reachExit" then
		onReachExit()
	elseif beat == "bump" then
		onBump()
	elseif beat == "done" then
		onDone()
	end
end

--------------------------------------------------------------------------------
-- Lifecycle (loader contract: Init no yields, Start spawned / connects remotes)
--------------------------------------------------------------------------------

function IntroFloorController:Init(_registry: any)
	-- Remotes.Get yields on the client, so the IntroBeat connection happens in
	-- Start. Nothing remote-bound is cached here, and this guide reaches no other
	-- controllers, so the registry is intentionally unused.
end

function IntroFloorController:Start()
	if started then
		return
	end
	started = true
	-- IntroBeat is owner-only (S->C). Connecting here (GetEvent yields) keeps the
	-- public Start() snappy and never blocks Init.
	Remotes.GetEvent("IntroBeat").OnClientEvent:Connect(onIntroBeat)
end

return IntroFloorController
