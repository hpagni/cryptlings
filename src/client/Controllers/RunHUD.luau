--!strict
-- CRYPTLINGS: NIGHT SHIFT — RunHUD (Stage 1, module mobile-run-ui).
-- The in-run heads-up display. Mobile-first (SOP §3.2): viewport-driven
-- UIScale, device safe-area insets, portrait-tolerant anchors, no tutorial
-- screens, every touch target >= 44px. Elements:
--   * Top shift timer driven by ShiftState.shiftEndsAt.
--   * Carried-case chips (tier colors) in maxCarry slots.
--   * Noise meter bar (NoiseMeter remote), green -> red: the greed dial.
--   * Downed overlay with bleedout ring (DOWNED_BLEEDOUT_SECONDS) and the
--     "a teammate can carry out your best box" loyalty hint (§1.2).
--   * Death -> "HAUL LOST" toast.
--   * Extraction banner: shows the shift pay earned this run, then auto-hides
--     after 8 seconds (no re-queue button).
--   * Defect heartbeat: polls distance to workspace's "Defect" model every
--     0.3s; under 40 studs ramps a red vignette + heartbeat thump (the cheap
--     jump-scare amplifier).

local CollectionService = game:GetService("CollectionService")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConstants = require(Shared:WaitForChild("Config"):WaitForChild("GameConstants"))
local RarityTable = require(Shared:WaitForChild("Config"):WaitForChild("RarityTable"))
local Remotes = require(Shared:WaitForChild("Net"):WaitForChild("Remotes"))

local LocalPlayer = Players.LocalPlayer

--------------------------------------------------------------------------------
-- HUD tuning (cosmetic, this module's domain)
--------------------------------------------------------------------------------

local DEFECT_TAG = "Defect" -- CollectionService tag set by DefectService on the live Defect model
local DEFECT_MODEL_NAME = "Defect" -- name fallback (direct workspace child) if the tag is absent
local HEARTBEAT_RANGE_STUDS = 40 -- vignette + heartbeat ramp under this range
local HEARTBEAT_POLL_SECONDS = 0.3
local HEARTBEAT_SOUND_ID = "rbxasset://sounds/bass.wav" -- placeholder thump

-- Design-space scaling: HUD authored against a ~450px short axis (budget
-- phone landscape height), clamped so desktop never balloons.
local DESIGN_SHORT_AXIS_PX = 450
local UISCALE_MIN = 0.85
local UISCALE_MAX = 1.6

local COLOR_PANEL = Color3.fromRGB(18, 20, 24)
local COLOR_TEXT = Color3.fromRGB(235, 238, 240)
local COLOR_TEXT_DIM = Color3.fromRGB(160, 166, 172)
local COLOR_NOISE_QUIET = Color3.fromRGB(85, 170, 85)
local COLOR_NOISE_LOUD = Color3.fromRGB(205, 60, 50)
local COLOR_DOWNED = Color3.fromRGB(120, 20, 20)
local COLOR_PAY = Color3.fromRGB(235, 190, 52)
local COLOR_CHIP_EMPTY = Color3.fromRGB(60, 64, 70)

-- Case tier -> chip color, same mapping CarryController uses for stacks
-- (T1 = Common grey, T2 = Rare blue baseline, T3 = Godly gold, §E palette).
local TIER_COLOR_KEYS: { [number]: string } =
	{ [1] = "Common", [2] = "Uncommon", [3] = "Rare", [4] = "Epic", [5] = "Legendary", [6] = "Mythical" }

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local RunHUD = {}

local registryRef: any = nil
local carryController: any = nil

local shiftStateName = "Intermission"
local shiftEndsAt: number? = nil

local maxCarry = GameConstants.BASE_CARRY_SLOTS
local lastNoise01 = 0

local localDowned = false
local downedEndsAt = 0
local downedBleedoutSeconds = GameConstants.DOWNED_BLEEDOUT_SECONDS
local downedCarryCount = 0

-- Gui refs (built in Start).
local uiScale: UIScale? = nil
local timerLabel: TextLabel? = nil
local healthFill: Frame? = nil
local healthLabel: TextLabel? = nil
local timerCaption: TextLabel? = nil
local noiseFill: Frame? = nil
local chipsRow: Frame? = nil
local downedOverlay: Frame? = nil
local reviveNowButton: TextButton? = nil
local reviveNowBusy = false -- a Consumable.Use("reviveBeacon") invoke is in flight
local downedRing: Frame? = nil
local downedRingLabel: TextLabel? = nil
local toastFrame: Frame? = nil
local toastLabel: TextLabel? = nil
local bannerFrame: Frame? = nil
local bannerPayLabel: TextLabel? = nil
local bannerCasesLabel: TextLabel? = nil
-- Fix #4: dead-screen respawn frame (server-owned skippable timer).
local respawnFrame: Frame? = nil
local respawnCountdownLabel: TextLabel? = nil
local respawnNowButton: TextButton? = nil
local respawnEndsAt: number? = nil -- workspace:GetServerTimeNow() deadline; nil = hidden
local respawnNowBusy = false -- a RequestRespawnNow invoke is in flight
local vignetteH: Frame? = nil
local vignetteV: Frame? = nil
local heartbeatSound: Sound? = nil

local toastToken = 0
local bannerToken = 0

--------------------------------------------------------------------------------
-- Small builders
--------------------------------------------------------------------------------

local function tierColor(tier: number): Color3
	local key = TIER_COLOR_KEYS[tier] or "Common"
	local color = (RarityTable.RARITY_COLORS :: any)[key]
	if typeof(color) == "Color3" then
		return color
	end
	return COLOR_CHIP_EMPTY
end

local function makeLabel(name: string, textSize: number, bold: boolean): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = name
	label.BackgroundTransparency = 1
	label.Font = if bold then Enum.Font.GothamBold else Enum.Font.Gotham
	label.TextSize = textSize
	label.TextColor3 = COLOR_TEXT
	label.TextStrokeTransparency = 0.7
	return label
end

local function makeRound(parent: GuiObject, radius: number)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius)
	corner.Parent = parent
end

local function makeCircle(parent: GuiObject)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = parent
end

--------------------------------------------------------------------------------
-- HUD construction
--------------------------------------------------------------------------------

local function buildHud(): ScreenGui
	local gui = Instance.new("ScreenGui")
	gui.Name = "RunHUD"
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = false
	gui.ScreenInsets = Enum.ScreenInsets.DeviceSafeInsets -- notch/safe-area aware
	gui.DisplayOrder = 10

	-- Vignette (full-bleed, behind everything; transparency animated by the
	-- Defect proximity loop). Two crossed gradients fake a radial vignette
	-- with zero image assets.
	local function makeVignette(name: string, rotation: number): Frame
		local frame = Instance.new("Frame")
		frame.Name = name
		frame.Size = UDim2.fromScale(1, 1)
		frame.BackgroundColor3 = COLOR_DOWNED
		frame.BackgroundTransparency = 1
		frame.BorderSizePixel = 0
		frame.ZIndex = 1
		local gradient = Instance.new("UIGradient")
		gradient.Rotation = rotation
		gradient.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.1),
			NumberSequenceKeypoint.new(0.35, 1),
			NumberSequenceKeypoint.new(0.65, 1),
			NumberSequenceKeypoint.new(1, 0.1),
		})
		gradient.Parent = frame
		frame.Parent = gui
		return frame
	end
	vignetteH = makeVignette("VignetteH", 0)
	vignetteV = makeVignette("VignetteV", 90)

	-- Scaled root for all panel content.
	local root = Instance.new("Frame")
	root.Name = "Root"
	root.Size = UDim2.fromScale(1, 1)
	root.BackgroundTransparency = 1
	root.ZIndex = 2
	root.Parent = gui

	local scale = Instance.new("UIScale")
	scale.Parent = root
	uiScale = scale

	-- Top center: shift timer.
	local timerPanel = Instance.new("Frame")
	timerPanel.Name = "ShiftTimer"
	timerPanel.AnchorPoint = Vector2.new(0.5, 0)
	timerPanel.Position = UDim2.new(0.5, 0, 0, 6)
	timerPanel.Size = UDim2.fromOffset(132, 44)
	timerPanel.BackgroundColor3 = COLOR_PANEL
	timerPanel.BackgroundTransparency = 0.25
	timerPanel.BorderSizePixel = 0
	timerPanel.Parent = root
	makeRound(timerPanel, 8)

	local caption = makeLabel("Caption", 10, false)
	caption.Position = UDim2.fromOffset(0, 3)
	caption.Size = UDim2.new(1, 0, 0, 12)
	caption.TextColor3 = COLOR_TEXT_DIM
	caption.Text = "NIGHT SHIFT"
	caption.Parent = timerPanel
	timerCaption = caption

	local timer = makeLabel("Time", 22, true)
	timer.Position = UDim2.fromOffset(0, 15)
	timer.Size = UDim2.new(1, 0, 0, 26)
	timer.Text = "--:--"
	timer.Parent = timerPanel
	timerLabel = timer

	-- Under the timer: noise meter (the greed dial).
	local noisePanel = Instance.new("Frame")
	noisePanel.Name = "NoiseMeter"
	noisePanel.AnchorPoint = Vector2.new(0.5, 0)
	noisePanel.Position = UDim2.new(0.5, 0, 0, 54)
	noisePanel.Size = UDim2.fromOffset(170, 10)
	noisePanel.BackgroundColor3 = COLOR_PANEL
	noisePanel.BackgroundTransparency = 0.25
	noisePanel.BorderSizePixel = 0
	noisePanel.Parent = root
	makeRound(noisePanel, 5)

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(0, 1)
	fill.BackgroundColor3 = COLOR_NOISE_QUIET
	fill.BorderSizePixel = 0
	fill.Parent = noisePanel
	makeRound(fill, 5)
	noiseFill = fill

	-- Under the noise meter: health bar (combat + Defect damage readout).
	local healthPanel = Instance.new("Frame")
	healthPanel.Name = "HealthBar"
	healthPanel.AnchorPoint = Vector2.new(0.5, 0)
	healthPanel.Position = UDim2.new(0.5, 0, 0, 68)
	healthPanel.Size = UDim2.fromOffset(170, 12)
	healthPanel.BackgroundColor3 = COLOR_PANEL
	healthPanel.BackgroundTransparency = 0.25
	healthPanel.BorderSizePixel = 0
	healthPanel.Parent = root
	makeRound(healthPanel, 6)

	local hpFill = Instance.new("Frame")
	hpFill.Name = "Fill"
	hpFill.Size = UDim2.fromScale(1, 1)
	hpFill.BackgroundColor3 = Color3.fromRGB(90, 210, 110)
	hpFill.BorderSizePixel = 0
	hpFill.Parent = healthPanel
	makeRound(hpFill, 6)
	healthFill = hpFill

	local hpLabel = makeLabel("Value", 10, true)
	hpLabel.Size = UDim2.fromScale(1, 1)
	hpLabel.Text = ""
	hpLabel.ZIndex = 3
	hpLabel.Parent = healthPanel
	healthLabel = hpLabel

	-- Top left: carried-case chips (maxCarry slots).
	local chips = Instance.new("Frame")
	chips.Name = "CarryChips"
	chips.Position = UDim2.fromOffset(10, 8)
	chips.Size = UDim2.fromOffset(200, 24)
	chips.BackgroundTransparency = 1
	chips.Parent = root
	local chipsLayout = Instance.new("UIListLayout")
	chipsLayout.FillDirection = Enum.FillDirection.Horizontal
	chipsLayout.Padding = UDim.new(0, 5)
	chipsLayout.SortOrder = Enum.SortOrder.LayoutOrder
	chipsLayout.Parent = chips
	chipsRow = chips

	-- Downed overlay (hidden until PlayerDownedState says otherwise).
	local overlay = Instance.new("Frame")
	overlay.Name = "DownedOverlay"
	overlay.Size = UDim2.fromScale(1, 1)
	overlay.BackgroundColor3 = COLOR_DOWNED
	overlay.BackgroundTransparency = 0.55
	overlay.BorderSizePixel = 0
	overlay.Visible = false
	overlay.ZIndex = 5
	overlay.Parent = root

	local ring = Instance.new("Frame")
	ring.Name = "BleedoutRing"
	ring.AnchorPoint = Vector2.new(0.5, 0.5)
	ring.Position = UDim2.fromScale(0.5, 0.42)
	ring.Size = UDim2.fromOffset(110, 110)
	ring.BackgroundColor3 = Color3.fromRGB(225, 80, 70)
	ring.BackgroundTransparency = 0.45
	ring.BorderSizePixel = 0
	ring.ZIndex = 6
	ring.Parent = overlay
	makeCircle(ring)
	local ringStroke = Instance.new("UIStroke")
	ringStroke.Color = Color3.fromRGB(255, 200, 195)
	ringStroke.Thickness = 3
	ringStroke.Parent = ring
	downedRing = ring

	local ringLabel = makeLabel("Seconds", 34, true)
	ringLabel.AnchorPoint = Vector2.new(0.5, 0.5)
	ringLabel.Position = UDim2.fromScale(0.5, 0.42)
	ringLabel.Size = UDim2.fromOffset(110, 40)
	ringLabel.ZIndex = 7
	ringLabel.Text = tostring(GameConstants.DOWNED_BLEEDOUT_SECONDS)
	ringLabel.Parent = overlay
	downedRingLabel = ringLabel

	local downedTitle = makeLabel("Title", 22, true)
	downedTitle.AnchorPoint = Vector2.new(0.5, 0.5)
	downedTitle.Position = UDim2.fromScale(0.5, 0.62)
	downedTitle.Size = UDim2.new(0.9, 0, 0, 28)
	downedTitle.ZIndex = 6
	downedTitle.Text = "YOU'RE DOWN"
	downedTitle.Parent = overlay

	local downedHint = makeLabel("Hint", 14, false)
	downedHint.AnchorPoint = Vector2.new(0.5, 0.5)
	downedHint.Position = UDim2.fromScale(0.5, 0.69)
	downedHint.Size = UDim2.new(0.9, 0, 0, 36)
	downedHint.TextWrapped = true
	downedHint.TextColor3 = Color3.fromRGB(255, 220, 215)
	downedHint.Text = "Hang on — a teammate can revive you, or carry out your best box."
	downedHint.Parent = overlay

	-- Paid self-revive (REVIVE_BEACON, §4.2): uses an owned beacon; otherwise
	-- raises the purchase prompt right here, and the grant auto-revives while
	-- still downed — the "pay to get back up" flow.
	local reviveNow = Instance.new("TextButton")
	reviveNow.Name = "ReviveNow"
	reviveNow.AnchorPoint = Vector2.new(0.5, 0.5)
	reviveNow.Position = UDim2.fromScale(0.5, 0.79)
	reviveNow.Size = UDim2.fromOffset(250, 48)
	reviveNow.BackgroundColor3 = Color3.fromRGB(235, 190, 52)
	reviveNow.BorderSizePixel = 0
	reviveNow.Font = Enum.Font.GothamBold
	reviveNow.TextSize = 17
	reviveNow.TextColor3 = Color3.fromRGB(18, 20, 24)
	reviveNow.Text = "REVIVE NOW — 75 R$"
	reviveNow.ZIndex = 6
	reviveNow.Parent = overlay
	makeRound(reviveNow, 12)
	reviveNowButton = reviveNow
	downedOverlay = overlay

	-- Toast (bottom center).
	local toast = Instance.new("Frame")
	toast.Name = "Toast"
	toast.AnchorPoint = Vector2.new(0.5, 1)
	toast.Position = UDim2.new(0.5, 0, 1, -86)
	toast.Size = UDim2.fromOffset(250, 40)
	toast.BackgroundColor3 = COLOR_PANEL
	toast.BackgroundTransparency = 0.15
	toast.BorderSizePixel = 0
	toast.Visible = false
	toast.ZIndex = 8
	toast.Parent = root
	makeRound(toast, 8)

	local toastText = makeLabel("Text", 16, true)
	toastText.Size = UDim2.fromScale(1, 1)
	toastText.ZIndex = 9
	toastText.Text = ""
	toastText.Parent = toast
	toastFrame = toast
	toastLabel = toastText

	-- Extraction banner (center): shift-pay summary; auto-hides after 8s.
	local banner = Instance.new("Frame")
	banner.Name = "ExtractionBanner"
	banner.AnchorPoint = Vector2.new(0.5, 0.5)
	banner.Position = UDim2.fromScale(0.5, 0.45)
	banner.Size = UDim2.fromOffset(280, 104)
	banner.BackgroundColor3 = COLOR_PANEL
	banner.BackgroundTransparency = 0.08
	banner.BorderSizePixel = 0
	banner.Visible = false
	banner.ZIndex = 10
	banner.Parent = root
	makeRound(banner, 12)

	local bannerTitle = makeLabel("Title", 20, true)
	bannerTitle.Position = UDim2.fromOffset(0, 10)
	bannerTitle.Size = UDim2.new(1, 0, 0, 24)
	bannerTitle.ZIndex = 11
	bannerTitle.Text = "SHIFT COMPLETE"
	bannerTitle.Parent = banner

	local bannerCases = makeLabel("Cases", 14, false)
	bannerCases.Position = UDim2.fromOffset(0, 38)
	bannerCases.Size = UDim2.new(1, 0, 0, 18)
	bannerCases.TextColor3 = COLOR_TEXT_DIM
	bannerCases.ZIndex = 11
	bannerCases.Text = ""
	bannerCases.Parent = banner
	bannerCasesLabel = bannerCases

	local bannerPay = makeLabel("Pay", 26, true)
	bannerPay.Position = UDim2.fromOffset(0, 58)
	bannerPay.Size = UDim2.new(1, 0, 0, 30)
	bannerPay.TextColor3 = COLOR_PAY
	bannerPay.ZIndex = 11
	bannerPay.Text = ""
	bannerPay.Parent = banner
	bannerPayLabel = bannerPay

	bannerFrame = banner

	-- Fix #4: dead-screen respawn panel (hidden in normal play). Shows only
	-- while the server-owned respawn timer is armed (RespawnTimer remote); a
	-- countdown plus a "RESPAWN NOW" skip button -> RequestRespawnNow. A
	-- dedicated full-bleed scrim above every other widget — it only appears
	-- after death (mutually exclusive with live HUD widgets), so it never
	-- overlaps the timer / noise / health / chips / banner during play.
	local respawn = Instance.new("Frame")
	respawn.Name = "RespawnScreen"
	respawn.Size = UDim2.fromScale(1, 1)
	respawn.BackgroundColor3 = Color3.fromRGB(8, 9, 12)
	respawn.BackgroundTransparency = 0.25
	respawn.BorderSizePixel = 0
	respawn.Visible = false
	respawn.ZIndex = 12
	respawn.Parent = root

	local respawnTitle = makeLabel("Title", 26, true)
	respawnTitle.AnchorPoint = Vector2.new(0.5, 0.5)
	respawnTitle.Position = UDim2.fromScale(0.5, 0.40)
	respawnTitle.Size = UDim2.new(0.9, 0, 0, 32)
	respawnTitle.ZIndex = 13
	respawnTitle.Text = "YOU DIED"
	respawnTitle.Parent = respawn

	local respawnCountdown = makeLabel("Countdown", 18, false)
	respawnCountdown.AnchorPoint = Vector2.new(0.5, 0.5)
	respawnCountdown.Position = UDim2.fromScale(0.5, 0.49)
	respawnCountdown.Size = UDim2.new(0.9, 0, 0, 24)
	respawnCountdown.TextColor3 = COLOR_TEXT_DIM
	respawnCountdown.ZIndex = 13
	respawnCountdown.Text = "Respawning…"
	respawnCountdown.Parent = respawn
	respawnCountdownLabel = respawnCountdown

	local respawnNow = Instance.new("TextButton")
	respawnNow.Name = "RespawnNow"
	respawnNow.AnchorPoint = Vector2.new(0.5, 0.5)
	respawnNow.Position = UDim2.fromScale(0.5, 0.60)
	respawnNow.Size = UDim2.fromOffset(250, 48)
	respawnNow.BackgroundColor3 = Color3.fromRGB(90, 210, 110)
	respawnNow.BorderSizePixel = 0
	respawnNow.Font = Enum.Font.GothamBold
	respawnNow.TextSize = 18
	respawnNow.TextColor3 = Color3.fromRGB(12, 16, 14)
	respawnNow.Text = "RESPAWN NOW"
	respawnNow.ZIndex = 13
	respawnNow.Parent = respawn
	makeRound(respawnNow, 12)
	respawnNowButton = respawnNow
	respawnFrame = respawn

	-- PC parity: tiny keybind reminder on non-touch devices only (not a
	-- tutorial screen — one dim line, §3.2).
	if not UserInputService.TouchEnabled then
		local hint = makeLabel("KeyHints", 12, false)
		hint.AnchorPoint = Vector2.new(1, 1)
		hint.Position = UDim2.new(1, -10, 1, -8)
		hint.Size = UDim2.fromOffset(280, 14)
		hint.TextXAlignment = Enum.TextXAlignment.Right
		hint.TextColor3 = COLOR_TEXT_DIM
		hint.TextTransparency = 0.35
		hint.Text = "SHIFT sprint   ·   E grab/drop   ·   F hold to revive"
		hint.Parent = root
	end

	-- Heartbeat thump lives in the gui (2D, local-only).
	local sound = Instance.new("Sound")
	sound.Name = "HeartbeatThump"
	sound.SoundId = HEARTBEAT_SOUND_ID
	sound.Volume = 0
	sound.Parent = gui
	heartbeatSound = sound

	return gui
end

--------------------------------------------------------------------------------
-- Viewport scaling (mobile-first: author at 450px short axis, clamp both ways)
--------------------------------------------------------------------------------

local function updateScale()
	local camera = workspace.CurrentCamera
	if camera == nil or uiScale == nil then
		return
	end
	local viewport = camera.ViewportSize
	local shortAxis = math.min(viewport.X, viewport.Y)
	if shortAxis <= 0 then
		return
	end
	uiScale.Scale = math.clamp(shortAxis / DESIGN_SHORT_AXIS_PX, UISCALE_MIN, UISCALE_MAX)
end

--------------------------------------------------------------------------------
-- Carry chips
--------------------------------------------------------------------------------

local function refreshChips()
	local row = chipsRow
	if row == nil then
		return
	end
	for _, child in row:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end

	local carried: { { uid: string, tier: number } } = {}
	if carryController ~= nil and type(carryController.GetLocalCarried) == "function" then
		carried = carryController.GetLocalCarried()
	end

	for slot = 1, maxCarry do
		local chip = Instance.new("Frame")
		chip.Name = `Chip{slot}`
		chip.LayoutOrder = slot
		chip.Size = UDim2.fromOffset(22, 22)
		chip.BorderSizePixel = 0
		local entry = carried[slot]
		if entry ~= nil then
			chip.BackgroundColor3 = tierColor(entry.tier)
			chip.BackgroundTransparency = 0.1
		else
			chip.BackgroundColor3 = COLOR_CHIP_EMPTY
			chip.BackgroundTransparency = 0.55
		end
		makeRound(chip, 6)
		chip.Parent = row
	end
end

--------------------------------------------------------------------------------
-- Toast
--------------------------------------------------------------------------------

-- Public so later stages (onboarding beats, shop grants) can reuse it.
function RunHUD.ShowToast(text: string, seconds: number?)
	local frame = toastFrame
	local label = toastLabel
	if frame == nil or label == nil then
		return
	end
	toastToken += 1
	local token = toastToken
	label.Text = text
	frame.Visible = true
	task.delay(seconds or 3, function()
		if toastToken == token then
			frame.Visible = false
		end
	end)
end

--------------------------------------------------------------------------------
-- Remote handlers
--------------------------------------------------------------------------------

local function onShiftState(payload: any)
	if type(payload) ~= "table" or type(payload.state) ~= "string" then
		return
	end
	shiftStateName = payload.state
	shiftEndsAt = if type(payload.shiftEndsAt) == "number" then payload.shiftEndsAt else nil

	if shiftStateName == "Active" then
		-- New shift: clear end-of-run UI.
		if bannerFrame ~= nil then
			bannerFrame.Visible = false
		end
	end
end

local function onNoiseMeter(payload: any)
	if type(payload) ~= "table" then
		return
	end
	if type(payload.noise01) == "number" then
		lastNoise01 = math.clamp(payload.noise01, 0, 1)
		local fill = noiseFill
		if fill ~= nil then
			fill.Size = UDim2.fromScale(lastNoise01, 1)
			fill.BackgroundColor3 = COLOR_NOISE_QUIET:Lerp(COLOR_NOISE_LOUD, lastNoise01)
		end
	end
	if type(payload.maxCarry) == "number" and payload.maxCarry ~= maxCarry then
		maxCarry = payload.maxCarry
		refreshChips()
	end
end

local function onPlayerDownedState(payload: any)
	if type(payload) ~= "table" or payload.userId ~= LocalPlayer.UserId then
		return
	end
	localDowned = payload.downed == true
	local overlay = downedOverlay
	if localDowned then
		-- Prefer the server-sent duration (it may vary later); fall back to §G.
		downedBleedoutSeconds = if type(payload.bleedoutSeconds) == "number"
			then payload.bleedoutSeconds
			else GameConstants.DOWNED_BLEEDOUT_SECONDS
		downedEndsAt = os.clock() + downedBleedoutSeconds
		downedCarryCount = if carryController ~= nil then carryController.GetLocalCount() else 0
		if overlay ~= nil then
			overlay.Visible = true
		end
	elseif overlay ~= nil then
		overlay.Visible = false
	end
end

local function onExtractionResult(payload: any)
	if type(payload) ~= "table" then
		return
	end
	if payload.extracted == true then
		local banked = if type(payload.bankedCaseUids) == "table" then #payload.bankedCaseUids else 0
		local pay = if type(payload.shiftPay) == "number" then payload.shiftPay else 0
		if bannerCasesLabel ~= nil then
			bannerCasesLabel.Text = if banked == 1
				then "1 CASE BANKED TO YOUR LOCKER"
				else `{banked} CASES BANKED TO YOUR LOCKER`
		end
		if bannerPayLabel ~= nil then
			bannerPayLabel.Text = `+{pay} SHIFT PAY`
		end
		if bannerFrame ~= nil then
			bannerFrame.Visible = true
			-- Auto-dismiss after 8s (token-guarded against a new shift / re-show).
			bannerToken += 1
			local token = bannerToken
			task.delay(8, function()
				if bannerToken == token and bannerFrame ~= nil then
					bannerFrame.Visible = false
				end
			end)
		end
	else
		RunHUD.ShowToast("CLOCKED OUT EMPTY-HANDED", 3)
	end
end

--------------------------------------------------------------------------------
-- Character / death
--------------------------------------------------------------------------------

-- Paid self-revive: consume an owned Revive Beacon; with none owned, raise
-- the purchase prompt (assetId 0 = not wired yet -> honest toast). A beacon
-- granted while still downed is auto-used via the ShopGrant hook in Start.
local function tryReviveNow()
	if not localDowned or reviveNowBusy then
		return
	end
	reviveNowBusy = true
	task.spawn(function()
		local ok, result = pcall(function()
			return Remotes.GetFunction("Consumable.Use"):InvokeServer("reviveBeacon")
		end)
		if ok and type(result) == "table" and result.ok ~= true and result.err == "NONE_OWNED" then
			local catalogOk, catalog = pcall(function()
				return Remotes.GetFunction("Shop.GetCatalog"):InvokeServer()
			end)
			if catalogOk and type(catalog) == "table" and type(catalog.items) == "table" then
				for _, entry in catalog.items :: { any } do
					if entry.sku == "REVIVE_BEACON" then
						local assetId = tonumber(entry.assetId) or 0
						if assetId > 0 then
							pcall(function()
								MarketplaceService:PromptProductPurchase(LocalPlayer, assetId)
							end)
						else
							RunHUD.ShowToast("REVIVE BEACON ISN'T ON SALE YET", 3)
						end
						break
					end
				end
			end
		elseif not ok then
			warn(`[RunHUD] revive-now invoke failed: {result}`)
		end
		reviveNowBusy = false
	end)
end

--------------------------------------------------------------------------------
-- Fix #4 — dead-screen respawn timer + skip button
--------------------------------------------------------------------------------

local function hideRespawnScreen()
	respawnEndsAt = nil
	respawnNowBusy = false
	if respawnFrame ~= nil then
		respawnFrame.Visible = false
	end
end

-- RespawnTimer remote: the server armed a respawn timer with a server-time
-- deadline. Show the dead screen and let the countdown loop tick it down.
local function onRespawnTimer(payload: any)
	if type(payload) ~= "table" or type(payload.endsAt) ~= "number" then
		return
	end
	respawnEndsAt = payload.endsAt
	respawnNowBusy = false
	local button = respawnNowButton
	if button ~= nil then
		button.AutoButtonColor = true
		button.Text = "RESPAWN NOW"
	end
	if respawnFrame ~= nil then
		respawnFrame.Visible = true
	end
end

-- Skip the wait: ask the server to respawn now. The server is the source of
-- truth (rejects NO_PENDING_RESPAWN); on success the next CharacterAdded hides
-- the screen, so we just disable the button while the invoke is in flight.
local function tryRespawnNow()
	if respawnEndsAt == nil or respawnNowBusy then
		return
	end
	respawnNowBusy = true
	local button = respawnNowButton
	if button ~= nil then
		button.AutoButtonColor = false
		button.Text = "RESPAWNING…"
	end
	task.spawn(function()
		local ok, result = pcall(function()
			return Remotes.GetFunction("RequestRespawnNow"):InvokeServer()
		end)
		if not ok then
			warn(`[RunHUD] respawn-now invoke failed: {result}`)
		end
		-- Re-enable on a reject so a NO_PENDING_RESPAWN race doesn't lock the
		-- button; a success is followed by CharacterAdded -> hideRespawnScreen.
		respawnNowBusy = false
		if button ~= nil and respawnEndsAt ~= nil then
			button.AutoButtonColor = true
			button.Text = "RESPAWN NOW"
		end
	end)
end

local function updateRespawnCountdown()
	if respawnEndsAt == nil then
		return
	end
	local remaining = math.max(0, respawnEndsAt - workspace:GetServerTimeNow())
	if respawnCountdownLabel ~= nil then
		respawnCountdownLabel.Text = `Respawning in {math.ceil(remaining)}…`
	end
end

-- Damage feedback (QOL): a hit flashes the red vignette hard for a beat so
-- damage registers even when eyes are nowhere near the health bar. The
-- Defect-proximity loop reclaims the vignette on its next 0.3s tick.
local lastKnownHealth = math.huge

local function flashDamage()
	for _, frame in { vignetteH, vignetteV } do
		if frame ~= nil then
			frame.BackgroundTransparency = 0.15
		end
	end
end

-- Health bar: live fill + green->red lerp as health drains.
local function updateHealthBar(humanoid: Humanoid)
	if lastKnownHealth ~= math.huge and humanoid.Health < lastKnownHealth - 2 then
		flashDamage()
	end
	lastKnownHealth = humanoid.Health
	local fill = healthFill
	if fill == nil then
		return
	end
	local maxHealth = math.max(humanoid.MaxHealth, 1)
	local ratio = math.clamp(humanoid.Health / maxHealth, 0, 1)
	fill.Size = UDim2.fromScale(ratio, 1)
	fill.BackgroundColor3 = Color3.fromRGB(220, 70, 60):Lerp(Color3.fromRGB(90, 210, 110), ratio)
	if healthLabel ~= nil then
		healthLabel.Text = `{math.floor(humanoid.Health + 0.5)} / {math.floor(maxHealth + 0.5)}`
	end
end

local function hookCharacter(character: Model)
	-- Fix #4: a fresh character means the (server-owned) respawn happened —
	-- hide the dead screen unconditionally on the next CharacterAdded.
	hideRespawnScreen()
	local humanoid = character:WaitForChild("Humanoid", 10)
	if humanoid == nil or not humanoid:IsA("Humanoid") then
		return
	end
	updateHealthBar(humanoid)
	humanoid.HealthChanged:Connect(function()
		updateHealthBar(humanoid)
	end)
	humanoid:GetPropertyChangedSignal("MaxHealth"):Connect(function()
		updateHealthBar(humanoid)
	end)
	humanoid.Died:Connect(function()
		if downedOverlay ~= nil then
			downedOverlay.Visible = false
		end
		localDowned = false
		local lostCount =
			math.max(downedCarryCount, if carryController ~= nil then carryController.GetLocalCount() else 0)
		downedCarryCount = 0
		if lostCount > 0 then
			RunHUD.ShowToast(
				if lostCount == 1
					then "HAUL LOST — YOUR CASE HIT THE FLOOR"
					else `HAUL LOST — {lostCount} CASES HIT THE FLOOR`,
				4
			)
		else
			RunHUD.ShowToast("YOU DIED — SHIFT OVER", 3)
		end
	end)
end

--------------------------------------------------------------------------------
-- Update loops
--------------------------------------------------------------------------------

local function formatClock(seconds: number): string
	local clamped = math.max(0, math.floor(seconds + 0.5))
	return string.format("%d:%02d", clamped // 60, clamped % 60)
end

local function updateTimer()
	local label = timerLabel
	local caption = timerCaption
	if label == nil or caption == nil then
		return
	end
	if shiftStateName == "Active" and shiftEndsAt ~= nil then
		caption.Text = "NIGHT SHIFT"
		label.Text = formatClock(shiftEndsAt - os.time())
	elseif shiftStateName == "Complete" then
		caption.Text = "NIGHT SHIFT"
		label.Text = "DONE"
	else
		caption.Text = "CLOCK-IN SOON"
		label.Text = if shiftEndsAt ~= nil then formatClock(shiftEndsAt - os.time()) else "--:--"
	end
end

local function updateBleedout()
	if not localDowned then
		return
	end
	local remaining = math.max(0, downedEndsAt - os.clock())
	local fraction = remaining / math.max(downedBleedoutSeconds, 1)
	local ring = downedRing
	if ring ~= nil then
		local px = math.floor(30 + 80 * fraction) -- ring shrinks as blood runs out
		ring.Size = UDim2.fromOffset(px, px)
	end
	if downedRingLabel ~= nil then
		downedRingLabel.Text = tostring(math.ceil(remaining))
	end
end

-- Defect heartbeat: cheap distance poll -> vignette + thump tempo.
local nextDefectPollAt = 0
local nextThumpAt = 0
local defectIntensity = 0 -- 0 far .. 1 on top of you

-- The live Defect: tagged instance anywhere under workspace (DefectService
-- parents it under the floor model), or a "Defect"-named direct child as a
-- fallback for untagged stand-ins.
local function findDefect(): Instance?
	-- Nearest tagged Defect to the local character: with concurrent shift
	-- floors (R2 Change 6) a first-match can key the vignette off another
	-- floor's monster 2000+ studs away; nearest-match is exact at that pitch.
	local character = LocalPlayer.Character
	local myRoot = character and character:FindFirstChild("HumanoidRootPart")
	local best: Instance? = nil
	local bestDistance = math.huge
	for _, tagged in CollectionService:GetTagged(DEFECT_TAG) do
		if tagged:IsDescendantOf(workspace) then
			if myRoot == nil or not myRoot:IsA("BasePart") then
				return tagged
			end
			local part: BasePart? = nil
			if tagged:IsA("Model") then
				part = tagged.PrimaryPart or tagged:FindFirstChildWhichIsA("BasePart")
			elseif tagged:IsA("BasePart") then
				part = tagged
			end
			if part ~= nil then
				local candidate = (part.Position - myRoot.Position).Magnitude
				if candidate < bestDistance then
					bestDistance = candidate
					best = tagged
				end
			end
		end
	end
	return best or workspace:FindFirstChild(DEFECT_MODEL_NAME)
end

local function pollDefect()
	defectIntensity = 0
	local character = LocalPlayer.Character
	local defect = findDefect()
	if character ~= nil and defect ~= nil then
		local root = character:FindFirstChild("HumanoidRootPart")
		local defectPart: BasePart? = nil
		if defect:IsA("Model") then
			defectPart = defect.PrimaryPart or defect:FindFirstChildWhichIsA("BasePart")
		elseif defect:IsA("BasePart") then
			defectPart = defect
		end
		if root ~= nil and root:IsA("BasePart") and defectPart ~= nil then
			local distance = (defectPart.Position - root.Position).Magnitude
			defectIntensity = math.clamp(1 - distance / HEARTBEAT_RANGE_STUDS, 0, 1)
		end
	end
	-- Vignette closes in as the Defect gets closer.
	local transparency = 1 - 0.65 * defectIntensity
	if vignetteH ~= nil then
		vignetteH.BackgroundTransparency = transparency
	end
	if vignetteV ~= nil then
		vignetteV.BackgroundTransparency = transparency
	end
end

local function updateHeartbeat(now: number)
	if defectIntensity <= 0 then
		return
	end
	if now >= nextThumpAt then
		-- Faster, louder thumps the closer it gets: 1.1s far -> 0.35s close.
		nextThumpAt = now + (1.1 - 0.75 * defectIntensity)
		local sound = heartbeatSound
		if sound ~= nil then
			sound.Volume = 0.15 + 0.5 * defectIntensity
			sound.PlaybackSpeed = 0.6
			sound:Play()
		end
	end
end

local hudAccumulator = 0

local function onHeartbeat(deltaTime: number)
	local now = os.clock()

	if now >= nextDefectPollAt then
		nextDefectPollAt = now + HEARTBEAT_POLL_SECONDS
		pollDefect()
	end
	updateHeartbeat(now)

	hudAccumulator += deltaTime
	if hudAccumulator >= 0.2 then
		hudAccumulator = 0
		updateTimer()
		updateBleedout()
		updateRespawnCountdown()
	end
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

function RunHUD.GetNoise01(): number
	return lastNoise01
end

function RunHUD.IsLocalDowned(): boolean
	return localDowned
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function RunHUD:Init(registry: any)
	registryRef = registry
end

function RunHUD:Start()
	if registryRef ~= nil and type(registryRef.Get) == "function" then
		carryController = registryRef.Get("CarryController")
	end

	local playerGui = LocalPlayer:WaitForChild("PlayerGui")
	local gui = buildHud()
	gui.Parent = playerGui

	updateScale()
	local camera = workspace.CurrentCamera
	if camera ~= nil then
		camera:GetPropertyChangedSignal("ViewportSize"):Connect(updateScale)
	end
	workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		local newCamera = workspace.CurrentCamera
		if newCamera ~= nil then
			newCamera:GetPropertyChangedSignal("ViewportSize"):Connect(updateScale)
			updateScale()
		end
	end)

	refreshChips()
	if carryController ~= nil and type(carryController.GetCarriedChangedSignal) == "function" then
		carryController.GetCarriedChangedSignal():Connect(function(userId: number)
			if userId == LocalPlayer.UserId then
				refreshChips()
			end
		end)
	end

	-- Remotes (Start may yield).
	local shiftState = Remotes.GetEvent("ShiftState")
	local noiseMeter = Remotes.GetEvent("NoiseMeter")
	local playerDownedState = Remotes.GetEvent("PlayerDownedState")
	local extractionResult = Remotes.GetEvent("ExtractionResult")

	shiftState.OnClientEvent:Connect(onShiftState)
	noiseMeter.OnClientEvent:Connect(onNoiseMeter)
	playerDownedState.OnClientEvent:Connect(onPlayerDownedState)
	extractionResult.OnClientEvent:Connect(onExtractionResult)

	-- Fix #4: dead-screen respawn timer + skip button.
	Remotes.GetEvent("RespawnTimer").OnClientEvent:Connect(onRespawnTimer)
	if respawnNowButton ~= nil then
		respawnNowButton.Activated:Connect(tryRespawnNow)
	end

	-- Paid self-revive wiring: the downed-overlay button, plus auto-use when a
	-- Revive Beacon purchase lands while the player is still down.
	if reviveNowButton ~= nil then
		reviveNowButton.Activated:Connect(tryReviveNow)
	end
	Remotes.GetEvent("ShopGrant").OnClientEvent:Connect(function(payload: any)
		if type(payload) == "table" and payload.sku == "REVIVE_BEACON" and localDowned then
			tryReviveNow()
		end
	end)

	if LocalPlayer.Character ~= nil then
		task.spawn(hookCharacter, LocalPlayer.Character)
	end
	LocalPlayer.CharacterAdded:Connect(function(character)
		task.spawn(hookCharacter, character)
	end)

	RunService.Heartbeat:Connect(onHeartbeat)
end

return RunHUD
