--!strict
-- CRYPTLINGS: NIGHT SHIFT — OnboardingController (Stage 2, module onboarding-first-shift).
-- Client half of the no-tutorial-screens first shift (SOP §3.2). Renders the
-- OnboardingBeat remote; veterans never receive a beat, so this controller
-- builds NOTHING until the first one arrives. Zero blocking modals — every
-- element is passive (subtitles, world markers, an edge arrow). Mobile-first:
-- viewport-driven UIScale, bottom-third placement clear of the thumb zones,
-- nothing interactive to fat-finger.
--
--   * Bottom-third subtitle bar: typewriter text (MaxVisibleGraphemes) + a
--     foreman audio blip per few characters.
--   * FirstCase: a billboard marker at the beat's case position (the server
--     also runs the physical beacon Part + beam); cleared the moment the local
--     player picks up any case (CaseEvent) or the next beat lands.
--   * FirstExtraction: soft directional arrow — a screen-edge chevron pointing
--     at the dock plus a "CLOCK OUT HERE" billboard at the dock itself.
--   * Done: one-time "OPEN YOUR CASE" pulse on the on-screen LockerChip tab —
--     the locker has no physical surface (R2 Addendum 1 Change 4); the beat
--     targets LockerUI's HUD chip, with a subtitle fallback.
--
-- Each beat is acked via FunnelClient {event="onboarding_ack", props={beat}}
-- (whitelisted server-side; AnalyticsService keys the onboarding_ack throttle
-- per beat, so back-to-back beats all land — analytics only, not flow control).
-- Visuals carry their own local failsafe timers so nothing can leak past the
-- server's 120s beat failsafe.
--
-- Public API (other controllers via Controllers.Get("OnboardingController")):
--   OnboardingController.IsActive() -> boolean  -- mid-first-shift beat

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Net"):WaitForChild("Remotes"))

local LocalPlayer = Players.LocalPlayer

--------------------------------------------------------------------------------
-- Tuning (cosmetic, this module's domain)
--------------------------------------------------------------------------------

local TYPEWRITER_CHARS_PER_SECOND = 28
local BLIP_EVERY_GRAPHEMES = 2
local BLIP_SOUND_ID = "rbxasset://sounds/electronicpingshort.wav" -- foreman PA blip (greybox audio)
local BLIP_VOLUME = 0.25
local SUBTITLE_HOLD_SECONDS = 6 -- non-sticky subtitles hide this long after fully typed
local MARKER_FAILSAFE_SECONDS = 150 -- local leak guard, outlasts the server's 120s beat failsafe
local DOCK_ARROW_EDGE_FRACTION = 0.36 -- arrow orbit radius as a fraction of the short viewport axis
local DOCK_ONSCREEN_HIDE_FRACTION = 0.30 -- hide the edge arrow when the dock is this close to screen center
local LOCKER_PULSE_TIMEOUT_SECONDS = 60
local LOCKER_CHIP_GUI_NAME = "LockerChip" -- LockerUI's HUD chip ScreenGui (the sole locker entry point, Change 4)
local LOCKER_CHIP_BUTTON_NAME = "Chip"
local LOCKER_PULSE_POLL_SECONDS = 0.25

-- Design-space scaling, same approach as RunHUD: authored against a ~450px
-- short axis (budget phone landscape), clamped so desktop never balloons.
local DESIGN_SHORT_AXIS_PX = 450
local UISCALE_MIN = 0.85
local UISCALE_MAX = 1.6

local COLOR_PANEL = Color3.fromRGB(18, 20, 24)
local COLOR_TEXT = Color3.fromRGB(235, 238, 240)
local COLOR_ACCENT = Color3.fromRGB(235, 190, 52) -- foreman/guidance gold
local COLOR_MARKER = Color3.fromRGB(235, 190, 52)

-- Fallback subtitle copy; the server normally ships `text` on every beat.
local DEFAULT_TEXT: { [string]: string } = {
	ClockIn = "NIGHT SHIFT — CLOCKED IN.",
	ForemanLine = "New hire! Grab a case, keep it quiet, and clock out at the dock. Don't meet the night staff.",
	FirstCase = "There — your first case. Grab it.",
	DefectFlyby = "Quiet! That's the night staff. Don't get heard.",
	FirstExtraction = "Now clock out — get that case to the dock.",
	Done = "Good work, new hire. Your case is banked — open it from your Locker tab.",
}

local SPEAKER_FOREMAN = "FOREMAN — PA"

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local OnboardingController = {}

local active = false
local doneSeen = false
local seenBeats: { [string]: boolean } = {}
local registryRef: any = nil -- Controllers registry (LockerUI.IsOpen dismissal check)

local gui: ScreenGui? = nil
local subtitleFrame: Frame? = nil
local subtitleLabel: TextLabel? = nil
local speakerLabel: TextLabel? = nil
local blipSound: Sound? = nil
local typeToken = 0

local fxFolder: Folder? = nil -- client-local world parts (markers)
local caseMarkerPart: BasePart? = nil
local caseMarkerToken = 0

local dockPosition: Vector3? = nil
local dockMarkerPart: BasePart? = nil
local arrowFrame: Frame? = nil
local arrowConnection: RBXScriptConnection? = nil
local dockToken = 0

local lockerPulseShown = false

local funnelRemote: RemoteEvent? = nil

--------------------------------------------------------------------------------
-- Gui construction (lazy: veterans never receive a beat, so never pay for this)
--------------------------------------------------------------------------------

local function applyUiScale(scale: UIScale)
	local camera = Workspace.CurrentCamera
	if camera == nil then
		return
	end
	local viewport = camera.ViewportSize
	local shortAxis = math.min(viewport.X, viewport.Y)
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
	screenGui.Name = "OnboardingGui"
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = true
	screenGui.DisplayOrder = 20 -- above RunHUD, below nothing modal (there are no modals)

	local scale = Instance.new("UIScale")
	scale.Parent = screenGui
	applyUiScale(scale)
	local camera = Workspace.CurrentCamera
	if camera ~= nil then
		camera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
			applyUiScale(scale)
		end)
	end

	-- Bottom-third subtitle bar.
	local bar = Instance.new("Frame")
	bar.Name = "SubtitleBar"
	bar.AnchorPoint = Vector2.new(0.5, 1)
	bar.Position = UDim2.fromScale(0.5, 0.84)
	bar.Size = UDim2.fromScale(0.86, 0)
	bar.AutomaticSize = Enum.AutomaticSize.Y
	bar.BackgroundColor3 = COLOR_PANEL
	bar.BackgroundTransparency = 0.25
	bar.BorderSizePixel = 0
	bar.Visible = false
	bar.Parent = screenGui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = bar

	local maxWidth = Instance.new("UISizeConstraint")
	maxWidth.MaxSize = Vector2.new(640, math.huge)
	maxWidth.Parent = bar

	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, 8)
	padding.PaddingBottom = UDim.new(0, 10)
	padding.PaddingLeft = UDim.new(0, 14)
	padding.PaddingRight = UDim.new(0, 14)
	padding.Parent = bar

	local speaker = Instance.new("TextLabel")
	speaker.Name = "Speaker"
	speaker.BackgroundTransparency = 1
	speaker.Size = UDim2.new(1, 0, 0, 14)
	speaker.Font = Enum.Font.GothamBold
	speaker.TextSize = 12
	speaker.TextColor3 = COLOR_ACCENT
	speaker.TextXAlignment = Enum.TextXAlignment.Left
	speaker.Text = ""
	speaker.Parent = bar

	local text = Instance.new("TextLabel")
	text.Name = "Subtitle"
	text.BackgroundTransparency = 1
	text.Position = UDim2.fromOffset(0, 16)
	text.Size = UDim2.fromScale(1, 0)
	text.AutomaticSize = Enum.AutomaticSize.Y
	text.Font = Enum.Font.Gotham
	text.TextSize = 18
	text.TextColor3 = COLOR_TEXT
	text.TextWrapped = true
	text.TextXAlignment = Enum.TextXAlignment.Left
	text.TextYAlignment = Enum.TextYAlignment.Top
	text.Text = ""
	text.Parent = bar

	local blip = Instance.new("Sound")
	blip.Name = "ForemanBlip"
	blip.SoundId = BLIP_SOUND_ID
	blip.Volume = BLIP_VOLUME
	blip.Parent = screenGui

	local playerGui = LocalPlayer:WaitForChild("PlayerGui")
	screenGui.Parent = playerGui

	gui = screenGui
	subtitleFrame = bar
	subtitleLabel = text
	speakerLabel = speaker
	blipSound = blip
	return screenGui
end

local function ensureFxFolder(): Folder
	local existing = fxFolder
	if existing ~= nil and existing.Parent ~= nil then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = "OnboardingClientFX"
	folder.Parent = Workspace
	fxFolder = folder
	return folder
end

--------------------------------------------------------------------------------
-- Subtitles (typewriter + foreman blip)
--------------------------------------------------------------------------------

local function showSubtitle(speaker: string?, text: string, sticky: boolean)
	ensureGui()
	local bar = subtitleFrame
	local label = subtitleLabel
	local speakerTag = speakerLabel
	if bar == nil or label == nil or speakerTag == nil then
		return
	end

	typeToken += 1
	local token = typeToken

	speakerTag.Text = speaker or ""
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
		if typeToken ~= token then
			return
		end
		label.MaxVisibleGraphemes = -1
		if not sticky then
			task.wait(SUBTITLE_HOLD_SECONDS)
			if typeToken == token then
				bar.Visible = false
			end
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
-- Billboard helpers (client-local greybox markers)
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

local function makeBillboard(adornee: Instance, text: string, color: Color3, studsOffset: Vector3): BillboardGui
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "OnboardingMarker"
	billboard.Adornee = adornee
	billboard.Size = UDim2.fromOffset(190, 46)
	billboard.StudsOffset = studsOffset
	billboard.AlwaysOnTop = true
	billboard.MaxDistance = 600

	local label = Instance.new("TextLabel")
	label.Name = "MarkerText"
	label.BackgroundColor3 = COLOR_PANEL
	label.BackgroundTransparency = 0.3
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.GothamBold
	label.TextSize = 18
	label.TextColor3 = color
	label.TextWrapped = true
	label.Text = text
	label.Parent = billboard

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = label

	-- Soft pulse so the marker reads as "look here" even in greybox.
	local tween = TweenService:Create(
		label,
		TweenInfo.new(0.7, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ TextTransparency = 0.35 }
	)
	tween:Play()

	billboard.Parent = adornee
	return billboard
end

--------------------------------------------------------------------------------
-- FirstCase marker
--------------------------------------------------------------------------------

local function clearCaseMarker()
	caseMarkerToken += 1
	if caseMarkerPart ~= nil then
		(caseMarkerPart :: BasePart):Destroy()
		caseMarkerPart = nil
	end
end

local function setCaseMarker(position: Vector3)
	local markerPosition = position + Vector3.new(0, 4.5, 0)
	if caseMarkerPart ~= nil and (caseMarkerPart :: BasePart).Parent ~= nil then
		-- Server retargeted the beacon (someone grabbed the highlighted case):
		-- just move the existing marker.
		(caseMarkerPart :: BasePart).Position = markerPosition
		return
	end
	clearCaseMarker()
	local part = makeMarkerPart("OnboardingCaseMarker", markerPosition)
	makeBillboard(part, "GRAB THIS CASE", COLOR_MARKER, Vector3.zero)
	caseMarkerPart = part

	caseMarkerToken += 1
	local token = caseMarkerToken
	task.delay(MARKER_FAILSAFE_SECONDS, function()
		if caseMarkerToken == token then
			clearCaseMarker()
		end
	end)
end

--------------------------------------------------------------------------------
-- FirstExtraction: dock billboard + soft screen-edge chevron
--------------------------------------------------------------------------------

local function buildArrowFrame(parent: ScreenGui): Frame
	local container = Instance.new("Frame")
	container.Name = "DockArrow"
	container.AnchorPoint = Vector2.new(0.5, 0.5)
	container.Size = UDim2.fromOffset(40, 40)
	container.BackgroundTransparency = 1
	container.Visible = false
	container.Parent = parent

	-- Two bars forming a ">" chevron pointing right at Rotation 0.
	local barTop = Instance.new("Frame")
	barTop.Name = "BarTop"
	barTop.AnchorPoint = Vector2.new(0.5, 0.5)
	barTop.Position = UDim2.fromOffset(22, 12)
	barTop.Size = UDim2.fromOffset(24, 5)
	barTop.Rotation = 45
	barTop.BackgroundColor3 = COLOR_ACCENT
	barTop.BorderSizePixel = 0
	barTop.Parent = container

	local barBottom = barTop:Clone()
	barBottom.Name = "BarBottom"
	barBottom.Position = UDim2.fromOffset(22, 28)
	barBottom.Rotation = -45
	barBottom.Parent = container

	for _, bar in { barTop, barBottom } do
		local tween = TweenService:Create(
			bar,
			TweenInfo.new(0.6, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
			{ BackgroundTransparency = 0.45 }
		)
		tween:Play()
	end
	return container
end

local function updateDockArrow()
	local arrow = arrowFrame
	local target = dockPosition
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
	-- Dock comfortably in view -> the billboard carries it; hide the chevron.
	if onScreen and direction.Magnitude < shortAxis * DOCK_ONSCREEN_HIDE_FRACTION then
		arrow.Visible = false
		return
	end

	local unit = if direction.Magnitude > 1 then direction.Unit else Vector2.new(0, -1)
	local radius = shortAxis * DOCK_ARROW_EDGE_FRACTION
	arrow.Visible = true
	arrow.Position = UDim2.fromOffset(center.X + unit.X * radius, center.Y + unit.Y * radius)
	arrow.Rotation = math.deg(math.atan2(unit.Y, unit.X))
end

local function stopDockGuidance()
	dockToken += 1
	dockPosition = nil
	if arrowConnection ~= nil then
		(arrowConnection :: RBXScriptConnection):Disconnect()
		arrowConnection = nil
	end
	if arrowFrame ~= nil then
		(arrowFrame :: Frame).Visible = false
	end
	if dockMarkerPart ~= nil then
		(dockMarkerPart :: BasePart):Destroy()
		dockMarkerPart = nil
	end
end

local function startDockGuidance(position: Vector3)
	stopDockGuidance()
	dockPosition = position

	local part = makeMarkerPart("OnboardingDockMarker", position + Vector3.new(0, 8, 0))
	makeBillboard(part, "CLOCK OUT HERE", COLOR_ACCENT, Vector3.zero)
	dockMarkerPart = part

	local screenGui = ensureGui()
	if arrowFrame == nil or (arrowFrame :: Frame).Parent == nil then
		arrowFrame = buildArrowFrame(screenGui)
	end
	arrowConnection = RunService.RenderStepped:Connect(updateDockArrow)

	dockToken += 1
	local token = dockToken
	task.delay(MARKER_FAILSAFE_SECONDS, function()
		if dockToken == token then
			stopDockGuidance()
		end
	end)
end

--------------------------------------------------------------------------------
-- Done: one-time "open your case" pulse on the on-screen LockerChip tab
-- (R2 Addendum 1 Change 4 — no world geometry; the screen chip IS the locker)
--------------------------------------------------------------------------------

local function findLockerChipButton(): GuiButton?
	local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if playerGui == nil then
		return nil
	end
	local chipGui = playerGui:FindFirstChild(LOCKER_CHIP_GUI_NAME)
	if chipGui == nil then
		return nil
	end
	local button = chipGui:FindFirstChild(LOCKER_CHIP_BUTTON_NAME, true)
	if button ~= nil and button:IsA("GuiButton") then
		return button
	end
	return nil
end

-- True once LockerUI reports open — the pulse has done its job.
local function isLockerOpen(): boolean
	local registry = registryRef
	if registry == nil or type(registry.Get) ~= "function" then
		return false
	end
	local lockerUI = registry.Get("LockerUI")
	if type(lockerUI) ~= "table" or type(lockerUI.IsOpen) ~= "function" then
		return false
	end
	local ok, open = pcall(lockerUI.IsOpen)
	return ok and open == true
end

local function showLockerPulse(freeOpens: number?)
	if lockerPulseShown then
		return -- one-time (spec)
	end
	lockerPulseShown = true

	local opensText = if type(freeOpens) == "number" then `{math.floor(freeOpens)} FREE` else "FREE"
	local button = findLockerChipButton()
	if button == nil then
		-- Chip not built yet (mid-construction client): the subtitle carries it.
		showSubtitle(nil, `Your case is waiting — open it from your Locker tab. ({opensText} opens today.)`, false)
		return
	end

	-- Highlight ring on the chip itself + a callout bubble beside it. Passive
	-- guidance only: the bubble never intercepts input, the chip stays the tap
	-- target, and everything is destroyed on dismiss.
	local ring = Instance.new("UIStroke")
	ring.Name = "OnboardingPulseRing"
	ring.Color = COLOR_ACCENT
	ring.Thickness = 3
	ring.Transparency = 0.1
	ring.Parent = button

	local bubble = Instance.new("TextLabel")
	bubble.Name = "OnboardingPulseBubble"
	bubble.AnchorPoint = Vector2.new(0, 0.5)
	bubble.Position = UDim2.new(1, 10, 0.5, 0)
	bubble.Size = UDim2.fromOffset(172, 44)
	bubble.BackgroundColor3 = COLOR_PANEL
	bubble.BackgroundTransparency = 0.25
	bubble.BorderSizePixel = 0
	bubble.Font = Enum.Font.GothamBold
	bubble.TextSize = 14
	bubble.TextColor3 = COLOR_ACCENT
	bubble.TextWrapped = true
	bubble.Text = `OPEN YOUR CASE — {opensText}`
	bubble.Parent = button
	local bubbleCorner = Instance.new("UICorner")
	bubbleCorner.CornerRadius = UDim.new(0, 8)
	bubbleCorner.Parent = bubble

	local pulse = TweenService:Create(
		ring,
		TweenInfo.new(0.7, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ Transparency = 0.7 }
	)
	pulse:Play()

	-- Dismiss the moment the locker opens (LockerUI takes over) or on the
	-- failsafe timeout. Zero blocking UI, nothing to tap away.
	task.spawn(function()
		local deadline = os.clock() + LOCKER_PULSE_TIMEOUT_SECONDS
		while os.clock() < deadline do
			task.wait(LOCKER_PULSE_POLL_SECONDS)
			if bubble.Parent == nil or isLockerOpen() then
				break
			end
		end
		pulse:Cancel()
		ring:Destroy()
		bubble:Destroy()
	end)
end

--------------------------------------------------------------------------------
-- Beat handling
--------------------------------------------------------------------------------

local function ack(beat: string)
	local remote = funnelRemote
	if remote ~= nil then
		remote:FireServer({ event = "onboarding_ack", props = { beat = beat } })
	end
end

local function parsePosition(value: any): Vector3?
	if
		type(value) == "table"
		and type(value[1]) == "number"
		and type(value[2]) == "number"
		and type(value[3]) == "number"
	then
		return Vector3.new(value[1], value[2], value[3])
	end
	return nil
end

local function onBeat(payload: any)
	if type(payload) ~= "table" or type(payload.beat) ~= "string" then
		return
	end
	local beat = payload.beat :: string
	local text = if type(payload.text) == "string" then payload.text :: string else DEFAULT_TEXT[beat]
	local position = parsePosition(payload.position)
	local repeated = seenBeats[beat] == true
	seenBeats[beat] = true

	if beat == "ClockIn" then
		active = true
		showSubtitle("NIGHT SHIFT", text or "", false)
	elseif beat == "ForemanLine" then
		active = true
		showSubtitle(SPEAKER_FOREMAN, text or "", false)
	elseif beat == "FirstCase" then
		active = true
		if position ~= nil then
			setCaseMarker(position)
		end
		if repeated then
			return -- beacon retarget: marker moved, no re-typed subtitle, no re-ack
		end
		showSubtitle(SPEAKER_FOREMAN, text or "", true)
	elseif beat == "DefectFlyby" then
		active = true
		clearCaseMarker()
		showSubtitle(SPEAKER_FOREMAN, text or "", false)
	elseif beat == "FirstExtraction" then
		active = true
		showSubtitle(SPEAKER_FOREMAN, text or "", true)
		if position ~= nil then
			startDockGuidance(position)
		end
	elseif beat == "Done" then
		active = false
		doneSeen = true
		clearCaseMarker()
		stopDockGuidance()
		showSubtitle(SPEAKER_FOREMAN, text or "", false)
		showLockerPulse(payload.freeOpens)
	else
		return -- unknown beat name: ignore (forward-compat)
	end

	ack(beat)
end

-- Snappier than waiting for the next beat: the moment WE pick up any case the
-- "grab this case" marker has done its job.
local function onCaseEvent(payload: any)
	if not active or doneSeen then
		return
	end
	if type(payload) ~= "table" or payload.kind ~= "PickedUp" then
		return
	end
	if payload.holderUserId == LocalPlayer.UserId then
		clearCaseMarker()
		if seenBeats.FirstCase and not seenBeats.DefectFlyby then
			hideSubtitle() -- the sticky "grab it" line is satisfied
		end
	end
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

function OnboardingController.IsActive(): boolean
	return active
end

--------------------------------------------------------------------------------
-- Loader lifecycle
--------------------------------------------------------------------------------

function OnboardingController:Init(registry: any)
	-- Nothing else to do until a beat arrives (Remotes.Get yields on the
	-- client, so all wiring happens in Start — the loader spawns it). The
	-- registry is kept for the Done-beat LockerUI.IsOpen dismissal check.
	registryRef = registry
end

function OnboardingController:Start()
	funnelRemote = Remotes.GetEvent("FunnelClient")
	Remotes.GetEvent("OnboardingBeat").OnClientEvent:Connect(onBeat)
	Remotes.GetEvent("CaseEvent").OnClientEvent:Connect(onCaseEvent)
end

return OnboardingController
