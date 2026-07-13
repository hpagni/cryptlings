--!strict
-- CRYPTLINGS: NIGHT SHIFT — CountdownUI (Stage 3 "Locker + 3-free-opens/day",
-- module rotation-countdown; SOP §3.3, §1.2, §4.3).
-- Renders RotationService's CountdownSync timers ({toyLineEndsAt,
-- nightlyRotationAt}, contract §B, every 30s):
--   * HUB WALL — REMOVED (R4-4): this module no longer renders any billboard
--     text on the "CountdownWall" slab. The slab itself, its tag and
--     HubService.GetCountdownWall() remain server-side contracts of record;
--     the slab simply stays bare. Ticking still runs locally every second
--     between syncs off workspace:GetServerTimeNow() (server-synchronized
--     unix clock, immune to device clock skew) for the chip and GetCountdowns.
--   * HUD CHIP — small top-right chip that appears only when the toy line has
--     <24h left. FOMO within policy (§4.3): scarcity and timers are allowed;
--     hiding odds is not. Non-Active, passes touch input through.
--   * ROTATION ANNOUNCEMENT — when nightlyRotationAt passes mid-session, a
--     one-shot client-side toast: "The factory floor is rearranging…" (the
--     seed is day-derived server-side, so the next intermission's floor is
--     already new — this is pure theater). The local deadline then advances a
--     day so the chip keeps ticking until the next authoritative sync.
--
-- Public API (Controllers.Get("CountdownUI")):
--   CountdownUI.GetCountdowns() -> { toyLineEndsAt: number, nightlyRotationAt: number, synced: boolean }
--
-- Mobile-first (§3.2): viewport-driven UIScale, safe-area insets, no buttons.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConstants = require(Shared:WaitForChild("Config"):WaitForChild("GameConstants"))
local Remotes = require(Shared:WaitForChild("Net"):WaitForChild("Remotes"))

local LocalPlayer = Players.LocalPlayer

--------------------------------------------------------------------------------
-- Tuning (cosmetic, this module's domain)
--------------------------------------------------------------------------------

local TOYLINE_DISPLAY_NAME = "PET LINE 1" -- launch line (RarityTable LINE_ID "line1"); display says Pets, never Toys

local TICK_SECONDS = 1 -- local re-render cadence between 30s syncs
local CHIP_THRESHOLD_SECONDS = 24 * 3600 -- HUD chip appears under 24h (§4.3)
local TOAST_SECONDS = 6
local ROTATION_TOAST_TEXT = "The factory floor is rearranging…"

local DESIGN_SHORT_AXIS_PX = 450 -- same mobile scaling model as BroadcastUI/RunHUD
local UISCALE_MIN = 0.85
local UISCALE_MAX = 1.6

local CHIP_WIDTH_PX = 168
local CHIP_HEIGHT_PX = 44
local CHIP_TOP_PX = 8 -- top-right: RunHUD owns top-center (timer/noise) and top-left (chips)

local TOAST_WIDTH_PX = 280
local TOAST_HEIGHT_PX = 40
local TOAST_BOTTOM_PX = 132 -- clears RunHUD's toast slot (bottom -86)

local COLOR_PANEL = Color3.fromRGB(18, 20, 24)
local COLOR_GOLD = Color3.fromRGB(235, 190, 52) -- godly/hazard gold: the scarcity color
local COLOR_TEXT = Color3.fromRGB(232, 230, 224)
local COLOR_TEXT_DIM = Color3.fromRGB(160, 166, 172)

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local CountdownUI = {}

local toyLineEndsAt = 0
local nightlyRotationAt = 0
local synced = false

local uiScale: UIScale? = nil
local chipFrame: Frame? = nil
local chipTimeLabel: TextLabel? = nil
local toastFrame: Frame? = nil
local toastLabel: TextLabel? = nil
local toastToken = 0

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

-- Server-synchronized unix time (same epoch as os.time() on the server), so
-- timers agree with RotationService even when the device clock is wrong.
local function serverNow(): number
	return Workspace:GetServerTimeNow()
end

-- "DDd HHh MMm" (spec format for the toy-line countdown chip).
local function formatToyLine(secondsLeft: number): string
	local s = math.max(0, math.floor(secondsLeft))
	local days = s // 86400
	local hours = (s % 86400) // 3600
	local minutes = (s % 3600) // 60
	return string.format("%dd %02dh %02dm", days, hours, minutes)
end

--------------------------------------------------------------------------------
-- Screen GUI (HUD chip + rotation toast)
--------------------------------------------------------------------------------

local function updateScale()
	local camera = Workspace.CurrentCamera
	if camera == nil or uiScale == nil then
		return
	end
	local shortAxis = math.min(camera.ViewportSize.X, camera.ViewportSize.Y)
	if shortAxis > 0 then
		uiScale.Scale = math.clamp(shortAxis / DESIGN_SHORT_AXIS_PX, UISCALE_MIN, UISCALE_MAX)
	end
end

local function buildScreenGui(): ScreenGui
	local gui = Instance.new("ScreenGui")
	gui.Name = "CountdownUI"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = false
	gui.ScreenInsets = Enum.ScreenInsets.DeviceSafeInsets
	gui.DisplayOrder = 12 -- above RunHUD (10), below the unboxing theater (20)

	local root = Instance.new("Frame")
	root.Name = "Root"
	root.Size = UDim2.fromScale(1, 1)
	root.BackgroundTransparency = 1
	root.Parent = gui

	local scale = Instance.new("UIScale")
	scale.Parent = root
	uiScale = scale

	-- <24h FOMO chip, top-right (RunHUD owns top-center and top-left).
	-- Non-Active frame + labels: touch input passes straight through.
	local chip = Instance.new("Frame")
	chip.Name = "ToyLineChip"
	chip.AnchorPoint = Vector2.new(1, 0)
	chip.Position = UDim2.new(1, -8, 0, CHIP_TOP_PX)
	chip.Size = UDim2.fromOffset(CHIP_WIDTH_PX, CHIP_HEIGHT_PX)
	chip.BackgroundColor3 = COLOR_PANEL
	chip.BackgroundTransparency = 0.15
	chip.BorderSizePixel = 0
	chip.Visible = false
	chip.Parent = root
	local chipCorner = Instance.new("UICorner")
	chipCorner.CornerRadius = UDim.new(0, 10)
	chipCorner.Parent = chip
	local chipStroke = Instance.new("UIStroke")
	chipStroke.Thickness = 1.5
	chipStroke.Color = COLOR_GOLD
	chipStroke.Parent = chip

	local chipCaption = Instance.new("TextLabel")
	chipCaption.Name = "Caption"
	chipCaption.BackgroundTransparency = 1
	chipCaption.Position = UDim2.fromOffset(0, 5)
	chipCaption.Size = UDim2.new(1, 0, 0, 12)
	chipCaption.Font = Enum.Font.GothamBold
	chipCaption.TextSize = 10
	chipCaption.TextColor3 = COLOR_TEXT_DIM
	chipCaption.Text = `{TOYLINE_DISPLAY_NAME} LEAVES IN`
	chipCaption.Parent = chip

	local chipTime = Instance.new("TextLabel")
	chipTime.Name = "Time"
	chipTime.BackgroundTransparency = 1
	chipTime.Position = UDim2.fromOffset(0, 18)
	chipTime.Size = UDim2.new(1, 0, 0, 22)
	chipTime.Font = Enum.Font.GothamBlack
	chipTime.TextSize = 18
	chipTime.TextColor3 = COLOR_GOLD
	chipTime.Text = ""
	chipTime.Parent = chip
	chipFrame = chip
	chipTimeLabel = chipTime

	-- Rotation toast, bottom-center, above RunHUD's toast slot.
	local toast = Instance.new("Frame")
	toast.Name = "RotationToast"
	toast.AnchorPoint = Vector2.new(0.5, 1)
	toast.Position = UDim2.new(0.5, 0, 1, -TOAST_BOTTOM_PX)
	toast.Size = UDim2.fromOffset(TOAST_WIDTH_PX, TOAST_HEIGHT_PX)
	toast.BackgroundColor3 = COLOR_PANEL
	toast.BackgroundTransparency = 0.15
	toast.BorderSizePixel = 0
	toast.Visible = false
	toast.Parent = root
	local toastCorner = Instance.new("UICorner")
	toastCorner.CornerRadius = UDim.new(0, 8)
	toastCorner.Parent = toast

	local toastText = Instance.new("TextLabel")
	toastText.Name = "Text"
	toastText.BackgroundTransparency = 1
	toastText.Size = UDim2.fromScale(1, 1)
	toastText.Font = Enum.Font.GothamBold
	toastText.TextSize = 15
	toastText.TextColor3 = COLOR_TEXT
	toastText.TextTruncate = Enum.TextTruncate.AtEnd
	toastText.Text = ""
	toastText.Parent = toast
	toastFrame = toast
	toastLabel = toastText

	return gui
end

local function showToast(text: string)
	local frame = toastFrame
	local label = toastLabel
	if frame == nil or label == nil then
		return
	end
	toastToken += 1
	local token = toastToken
	label.Text = text
	frame.Visible = true
	task.delay(TOAST_SECONDS, function()
		if toastToken == token and frame ~= nil then
			frame.Visible = false
		end
	end)
end

--------------------------------------------------------------------------------
-- Render tick
--------------------------------------------------------------------------------

local function render()
	if not synced then
		return -- placeholders ("--") until the first CountdownSync lands
	end

	local now = serverNow()

	-- One-shot hub PA: rotation deadline just passed. The server seed is
	-- day-derived, so the next intermission's floor is already new — announce,
	-- then tick toward the next boundary until the authoritative sync corrects.
	if now >= nightlyRotationAt then
		-- Catch up in one step (a suspended mobile session can resume days
		-- later) so the toast fires exactly once per wake.
		repeat
			nightlyRotationAt += GameConstants.SECONDS_PER_DAY
		until nightlyRotationAt > now
		showToast(ROTATION_TOAST_TEXT)
	end

	local toyLineLeft = toyLineEndsAt - now

	-- <24h FOMO chip (§4.3: timers allowed).
	local chip = chipFrame
	if chip ~= nil then
		local showChip = toyLineLeft < CHIP_THRESHOLD_SECONDS
		if showChip and chipTimeLabel ~= nil then
			chipTimeLabel.Text = formatToyLine(toyLineLeft)
		end
		chip.Visible = showChip
	end
end

local function onCountdownSync(payload: any)
	if
		type(payload) ~= "table"
		or type(payload.toyLineEndsAt) ~= "number"
		or type(payload.nightlyRotationAt) ~= "number"
	then
		return
	end
	toyLineEndsAt = payload.toyLineEndsAt
	nightlyRotationAt = payload.nightlyRotationAt
	synced = true
	render() -- snap to authority immediately rather than waiting out the tick
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- Last authoritative deadlines (locally advanced past a rotation flip until the
-- next sync). Zeros with synced=false before the first CountdownSync.
function CountdownUI.GetCountdowns(): { toyLineEndsAt: number, nightlyRotationAt: number, synced: boolean }
	return {
		toyLineEndsAt = toyLineEndsAt,
		nightlyRotationAt = nightlyRotationAt,
		synced = synced,
	}
end

--------------------------------------------------------------------------------
-- Loader lifecycle
--------------------------------------------------------------------------------

function CountdownUI:Start()
	-- Everything lives in Start (spawned): Remotes.Get yields on the client and
	-- Init must not (§A loader contract; also keeps the <45s mobile join light).
	local playerGui = LocalPlayer:WaitForChild("PlayerGui")

	local screenGui = buildScreenGui()
	screenGui.Parent = playerGui

	updateScale()
	local camera = Workspace.CurrentCamera
	if camera ~= nil then
		camera:GetPropertyChangedSignal("ViewportSize"):Connect(updateScale)
	end

	Remotes.GetEvent("CountdownSync").OnClientEvent:Connect(onCountdownSync)

	-- Live tick: 1s chip updates between the 30s authoritative syncs.
	while true do
		render()
		task.wait(TICK_SECONDS)
	end
end

return CountdownUI
