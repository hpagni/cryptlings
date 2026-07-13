--!strict
-- CRYPTLINGS: NIGHT SHIFT — BikeController (Addendum 2 R3-5; R3 plan WP2.2).
-- The on-screen BikeChip is the lobby bicycle's sole entry point: one tap asks
-- the server to mount, another tap to dismount, via the "Bike.SetActive"
-- RemoteFunction. BikeService (server) owns ALL bike authority — grant checks
-- (lobby radius, alive, never on a shift), the welded cosmetic model, the rate
-- limit, and every auto-dismount rule. This controller renders state and
-- forwards taps; it never moves or modifies the character:
--   * Rail slot: directly ABOVE LockerChip on the left chip rail — locker at
--     (8, 0.56, +0), shop +74, pets +150; the bike takes the -74 slot
--     (-(CHIP_HEIGHT_PX + 6)). Verified free this change set; on a 375 px-tall
--     viewport the chip spans ~102..170 px, clear of RunHUD's top cluster
--     (top-left carry chips end well above ~51 px even at max UIScale).
--   * Pressed/filled style follows the server-set "BikeActive" player
--     attribute (server truth) — NEVER the InvokeServer reply. The attribute
--     flip also covers every BikeService auto-dismount (death, seats,
--     queue/trade pads, dispatch, out-of-bounds) with zero extra wiring.
--   * Hidden on factory floors: mirrors the LockerChip ShiftState gating —
--     hide while state == "Active" and participant == true (R3-5: the chip
--     and the bike never co-exist with a run; the server refuses ON_SHIFT
--     anyway — this is UX, not authority).
--   * Speed is NOT applied here: GameConstants.BIKE_SPEED_MULT is folded into
--     the two existing speed owners (server CaseService.ApplyCarrySpeed and
--     the InputController client formula) off the BikeActive attribute, with
--     max(bike path, sprint path) precedence — never a third writer
--     (PetPerks line 8 rule). This file is UI only.
--   * Desktop keybind deliberately omitted: the brief's optional Q is already
--     bound to ACTION_ATTACK ("FIGHT") in InputController; the chip is the
--     single entry point on every platform.
--
-- Public API (Controllers.Get("BikeController")):
--   BikeController.IsActive() -> boolean -- server-set BikeActive mirror

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConstants = require(Shared:WaitForChild("Config"):WaitForChild("GameConstants"))
local LobbyConfig = require(Shared:WaitForChild("Config"):WaitForChild("LobbyConfig"))
local Remotes = require(Shared:WaitForChild("Net"):WaitForChild("Remotes"))

local LocalPlayer = Players.LocalPlayer

--------------------------------------------------------------------------------
-- Tuning (cosmetic, this module's domain)
--------------------------------------------------------------------------------

-- Touch sizing: the LockerChip idiom — same 84x68 chip, >= the §G 44 px gate.
local MIN_TOUCH_PX = GameConstants.MOBILE_MIN_TOUCH_TARGET_PX -- 44
local CHIP_WIDTH_PX = 84
local CHIP_HEIGHT_PX = math.max(MIN_TOUCH_PX, 68)

-- One tap = one InvokeServer; brief debounce so a double-tap can't queue two
-- conflicting toggles (the server's 5/10 s rate limit is the real wall).
local DEBOUNCE_SECONDS = 0.3

-- Palette (matches the LockerUI/RunHUD greybox chrome). Accent = the bike's
-- own Neon strip color so chip and cosmetic read as one system.
local COLOR_PANEL = Color3.fromRGB(18, 20, 24)
local COLOR_PANEL_PRESSED = Color3.fromRGB(30, 33, 39)
local COLOR_TEXT = Color3.fromRGB(235, 238, 240)
local COLOR_TEXT_DIM = Color3.fromRGB(160, 166, 172)
local COLOR_ACCENT = Color3.fromRGB(
	LobbyConfig.BIKE.NEON_STRIP_COLOR.R,
	LobbyConfig.BIKE.NEON_STRIP_COLOR.G,
	LobbyConfig.BIKE.NEON_STRIP_COLOR.B
)

-- Same rail layer as LockerChip (LockerUI DISPLAY_ORDER 16 - 1).
local DISPLAY_ORDER = 15

-- Server error -> player-facing toast copy (contract in Remotes.luau).
local ERR_TEXT: { [string]: string } = {
	BAD_ARG = "SOMETHING JAMMED — TRY AGAIN",
	ON_SHIFT = "NO BIKES ON THE FACTORY FLOOR",
	OUT_OF_BOUNDS = "BIKES STAY ON THE HUB STREET",
	DEAD = "YOU'RE IN NO SHAPE TO RIDE",
	RATE_LIMIT = "EASY ON THE PEDALS — TRY AGAIN",
	FAILED = "SOMETHING JAMMED — TRY AGAIN",
}

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local BikeController = {}

local registryRef: any = nil

type ChipRefs = {
	gui: ScreenGui,
	button: TextButton,
	stroke: UIStroke,
	glyph: TextLabel,
	sub: TextLabel,
}
local chip: ChipRefs? = nil

local shiftStateName = "Intermission"
local shiftParticipant = false

local invokeBusy = false -- a Bike.SetActive invoke is in flight
local debounceUntil = 0

local bikeSetActive: RemoteFunction? = nil

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

-- Server truth: the BikeService-set display mirror, never local toggle state.
local function isMounted(): boolean
	return LocalPlayer:GetAttribute("BikeActive") == true
end

local function toast(text: string)
	if registryRef == nil or type(registryRef.Get) ~= "function" then
		return
	end
	local runHud = registryRef.Get("RunHUD")
	if runHud ~= nil and type(runHud.ShowToast) == "function" then
		pcall(runHud.ShowToast, text, 3)
	end
end

local function makeRound(parent: GuiObject, radius: number)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius)
	corner.Parent = parent
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

--------------------------------------------------------------------------------
-- Chip render
--------------------------------------------------------------------------------

local function updateChip()
	local refs = chip
	if refs == nil then
		return
	end
	local mounted = isMounted()
	refs.button.BackgroundColor3 = if mounted then COLOR_PANEL_PRESSED else COLOR_PANEL
	refs.stroke.Transparency = if mounted then 0.05 else 0.4
	refs.glyph.TextColor3 = if mounted then COLOR_ACCENT else COLOR_TEXT
	refs.sub.Text = if mounted then "RIDING" else "TAP TO RIDE"
	refs.sub.TextColor3 = if mounted then COLOR_ACCENT else COLOR_TEXT_DIM
	-- Hidden on factory floors (R3-5; mirrors the LockerChip ShiftState gate).
	refs.button.Visible = not (shiftStateName == "Active" and shiftParticipant)
end

local function onChipTap()
	if invokeBusy or os.clock() < debounceUntil then
		return
	end
	debounceUntil = os.clock() + DEBOUNCE_SECONDS
	local remote = bikeSetActive
	if remote == nil then
		return
	end
	-- Toggle off the server-set attribute, not a local flag, so a missed reply
	-- or server-side auto-dismount can never invert the chip's intent.
	local target = not isMounted()
	invokeBusy = true
	task.spawn(function()
		local ok, result = pcall(function()
			return remote:InvokeServer(target)
		end)
		if not ok then
			warn(`[BikeController] Bike.SetActive invoke failed: {result}`)
		elseif type(result) == "table" and result.ok ~= true and result.err ~= nil then
			toast(ERR_TEXT[tostring(result.err)] or ERR_TEXT.FAILED)
		end
		invokeBusy = false
	end)
end

local function buildChip()
	local gui = Instance.new("ScreenGui")
	gui.Name = "BikeChip"
	gui.ResetOnSpawn = false
	gui.ScreenInsets = Enum.ScreenInsets.DeviceSafeInsets
	gui.DisplayOrder = DISPLAY_ORDER

	local button = Instance.new("TextButton")
	button.Name = "Chip"
	button.AnchorPoint = Vector2.new(0, 0.5)
	-- One chip slot ABOVE LockerChip on the left rail (see header).
	button.Position = UDim2.new(0, 8, 0.56, -(CHIP_HEIGHT_PX + 6))
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
	caption.Text = "BIKE"
	caption.Parent = button

	-- Bicycle silhouette glyph (text glyph — acceptable in greybox, WP2.2).
	local glyph = makeLabel("Glyph", 24, true)
	glyph.Position = UDim2.fromOffset(0, 18)
	glyph.Size = UDim2.new(1, 0, 0, 26)
	glyph.Text = "🚲"
	glyph.Parent = button

	local sub = makeLabel("Sub", 11, true)
	sub.Position = UDim2.new(0, 0, 1, -18)
	sub.Size = UDim2.new(1, 0, 0, 14)
	sub.TextColor3 = COLOR_TEXT_DIM
	sub.Text = "TAP TO RIDE"
	sub.Parent = button

	chip = { gui = gui, button = button, stroke = stroke, glyph = glyph, sub = sub }
	gui.Parent = LocalPlayer:WaitForChild("PlayerGui")

	button.Activated:Connect(onChipTap)
	updateChip()
end

--------------------------------------------------------------------------------
-- Server event handlers
--------------------------------------------------------------------------------

local function onShiftState(payload: any)
	if type(payload) ~= "table" or type(payload.state) ~= "string" then
		return
	end
	shiftStateName = payload.state
	shiftParticipant = payload.participant == true
	updateChip()
end

--------------------------------------------------------------------------------
-- Public API (via Controllers.Get("BikeController"))
--------------------------------------------------------------------------------

function BikeController.IsActive(): boolean
	return isMounted()
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function BikeController:Init(registry: any)
	registryRef = registry
end

function BikeController:Start()
	buildChip()

	-- Resolve the remote (Remotes.Get* may yield on the client; Start may
	-- yield, Init may not — house rule).
	bikeSetActive = Remotes.GetFunction("Bike.SetActive")

	Remotes.GetEvent("ShiftState").OnClientEvent:Connect(onShiftState)

	-- Server truth drives the pressed/filled state: react to the attribute
	-- flip, not the InvokeServer reply — this also catches every BikeService
	-- auto-dismount (death, seats, queue/trade pads, dispatch, bounds).
	LocalPlayer:GetAttributeChangedSignal("BikeActive"):Connect(updateChip)

	updateChip()
end

return BikeController
