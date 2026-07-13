--!strict
-- CRYPTLINGS: NIGHT SHIFT — UnboxingUI (Stage 2, module unboxing-theater-ui).
-- The full-screen unboxing theater (SOP §3.1 ②): banked cases open in a
-- slow-peel reveal with confetti, exact odds one tap away (OddsUI), and the
-- whole composition kept 16:9-safe and centered so the record-pull clip
-- format (§1.4) frames itself.
--
-- Public API (Controllers.Get("UnboxingUI"); Stage 3 LockerUI calls it):
--   PlayOpen(caseStub) -> response  -- yields for the whole theater flow.
--       caseStub: Types.CaseStub (uid + tier are all we read).
--       response: the RequestOpenCase reply table
--                 {ok, cryptlingId?, rarity?, isDuplicate?, opensRemaining?, err?}
--                 plus client-side errs "BUSY" | "BAD_STUB" | "CANCELLED" | "TIMEOUT".
--   IsBusy() -> boolean
--
-- Flow: ViewportFrame greybox case on a pedestal -> SLOW-PEEL: touch-drag (or
-- mouse-drag) the tape strip across the case top over ~3s with shake,
-- resistance easing and rising audio -> release past 90% commits ->
-- RequestOpenCase -> 0.8s heartbeat suspense -> rarity color flash fills the
-- screen edges -> confetti ParticleEmitter burst on a stage anchor (count and
-- duration scale by rarity: Common 20 -> Godly 400 + gold beams + slow-mo FOV
-- punch) -> the Cryptling assembles live from its RarityTable recipe in the
-- viewport -> name card in rarity color, "DUPLICATE" tag when isDuplicate.
-- NO_OPENS -> friendly "locker's locked" toast. Full peel -> confetti ->
-- reveal stays comfortably under the 12s acceptance bar.
--
-- Mobile-first (§3.2/§G): every touch target >= 44px, viewport-driven UIScale,
-- device safe-area insets, one-thumb drag gesture.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConstants = require(Shared:WaitForChild("Config"):WaitForChild("GameConstants"))
local RarityFX = require(Shared:WaitForChild("Config"):WaitForChild("RarityFX"))
local RarityTable = require(Shared:WaitForChild("Config"):WaitForChild("RarityTable"))
local Remotes = require(Shared:WaitForChild("Net"):WaitForChild("Remotes"))

local LocalPlayer = Players.LocalPlayer

--------------------------------------------------------------------------------
-- Theater tuning (cosmetic, this module's domain)
--------------------------------------------------------------------------------

local PEEL_TARGET_SECONDS = 3 -- design length of a committed full peel
local PEEL_COMMIT_FRACTION = 0.9 -- release past this -> the case opens
local PEEL_MAX_RATE = 1.25 / PEEL_TARGET_SECONDS -- progress/s while dragging, before resistance
local PEEL_RESISTANCE = 0.5 -- rate shrinks by this fraction at full peel (heavy last stretch)
local PEEL_RETURN_RATE = 1.6 -- progress/s springing back after an uncommitted release
local SUSPENSE_SECONDS = 0.8 -- heartbeat beat between commit and reveal
local OPEN_RESPONSE_TIMEOUT_SECONDS = 8 -- server reply guard so the theater can never hang
-- Reveal pacing per rarity (assemble = seconds between recipe parts snapping
-- in; soak = turntable time before auto-close). Commons snap together fast and
-- get out of the way; the long clip-able celebration is reserved for Rare+.
local REVEAL_PACING: { [string]: { assemble: number, soak: number } } = {
	Common = { assemble = 0.05, soak = 4 },
	Uncommon = { assemble = 0.06, soak = 5 },
	Rare = { assemble = 0.12, soak = 12 },
	Epic = { assemble = 0.16, soak = 20 },
	Legendary = { assemble = 0.2, soak = 30 },
	Godly = { assemble = 0.22, soak = 35 },
	Mythical = { assemble = 0.25, soak = 45 },
}
local SPIN_RADIANS_PER_SECOND = 0.7 -- assembled Cryptling turntable

-- Confetti scale by rarity (count, seconds of fall worth of lifetime).
local CONFETTI_COUNT: { [string]: number } =
	{ Common = 20, Uncommon = 60, Rare = 130, Epic = 240, Legendary = 400, Godly = 520, Mythical = 700 }
local CONFETTI_SECONDS: { [string]: number } =
	{ Common = 1.2, Uncommon = 1.5, Rare = 1.9, Epic = 2.4, Legendary = 3.0, Godly = 3.4, Mythical = 4.0 }
local REVEAL_VOLUME: { [string]: number } =
	{ Common = 0.35, Uncommon = 0.45, Rare = 0.6, Epic = 0.75, Legendary = 0.9, Godly = 0.95, Mythical = 1 }

-- Design-space scaling: authored against a ~450px short axis (budget phone
-- landscape height), clamped so desktop never balloons. Same recipe as RunHUD.
local DESIGN_SHORT_AXIS_PX = 450
local UISCALE_MIN = 0.85
local UISCALE_MAX = 1.6

-- Touch sizing — everything comfortably over the 44px gate (§G).
local STRIP_WIDTH_PX = 300
local STRIP_HEIGHT_PX = 64
local HANDLE_PX = 56
local CANCEL_PX = 48
local CONTINUE_HEIGHT_PX = 54

local COLOR_PANEL = Color3.fromRGB(18, 20, 24)
local COLOR_TEXT = Color3.fromRGB(235, 238, 240)
local COLOR_TEXT_DIM = Color3.fromRGB(160, 166, 172)
local COLOR_DIM = Color3.fromRGB(8, 9, 12)
local COLOR_TAPE = Color3.fromRGB(240, 234, 210)
local COLOR_PEDESTAL = Color3.fromRGB(52, 55, 62)
local COLOR_GOLD = Color3.fromRGB(235, 190, 52)
local COLOR_FALLBACK = Color3.fromRGB(178, 178, 178)

local DIM_TRANSPARENCY = 0.35 -- semi-transparent so the 3D confetti burst reads through

-- Case tier -> greybox color, same mapping RunHUD/CarryController use
-- (T1 = Common grey, T2 = Rare blue baseline, T3 = Godly gold, §E palette).
local TIER_COLOR_KEYS: { [number]: string } =
	{ [1] = "Common", [2] = "Uncommon", [3] = "Rare", [4] = "Epic", [5] = "Legendary", [6] = "Mythical" }

local SOUND_TICK = "rbxasset://sounds/electronicpingshort.wav"
local SOUND_THUMP = "rbxasset://sounds/bass.wav"
local SOUND_SNAP = "rbxasset://sounds/snap.mp3"
local SOUND_FANFARE = "rbxasset://sounds/victory.wav"

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local UnboxingUI = {}

local registryRef: any = nil
local oddsUI: any = nil

-- First-person cursor release (R4-2): the token is held for the whole theater
-- (openTheater -> closeTheater, spanning the PlayOpen yield). Registry lookup,
-- nil-guarded: a missing CursorUnlock degrades to a no-op.
local CURSOR_TOKEN = "UnboxingUI"

local function setCursorReleased(released: boolean)
	if registryRef == nil or type(registryRef.Get) ~= "function" then
		return
	end
	local cursorUnlock = registryRef.Get("CursorUnlock")
	if cursorUnlock == nil then
		return
	end
	if released then
		cursorUnlock.acquire(CURSOR_TOKEN)
	else
		cursorUnlock.release(CURSOR_TOKEN)
	end
end

local busy = false
local phase: "Idle" | "Peel" | "Suspense" | "Reveal" = "Idle"

-- Peel gesture state.
local peelProgress = 0
local dragTarget = 0
local dragAccumPx = 0
local dragging = false
local dragInput: InputObject? = nil
local lastDragX = 0
local committed = false
local cancelRequested = false
local lastTickProgress = 0

-- Reveal state.
local continuePressed = false
local spinConnection: RBXScriptConnection? = nil

-- Tier-odds popup pinned under the case (§8.1 + playtest request).
local oddsPanel: Frame? = nil
local oddsTitleLabel: TextLabel? = nil
local oddsRows: { TextLabel } = {}
local oddsToken = 0

-- Viewport model bookkeeping: parts + their authored CFrames, so shake and
-- turntable spin are pure transforms over a stable base. `container` is the
-- Model the reveal parts live in (RarityFX.Apply target; nil for the case).
type ViewportModel = { parts: { BasePart }, base: { CFrame }, container: Model? }
local caseModel: ViewportModel? = nil
local caseLid: BasePart? = nil
local caseTape: BasePart? = nil
local caseTapeBase: CFrame? = nil
local caseTapeWidth = 0
local revealModel: ViewportModel? = nil

local toastToken = 0

-- All gui refs live here (built lazily on first PlayOpen so the join-to-playing
-- path stays light, §G MOBILE_MAX_JOIN_SECONDS).
local ui: any = nil

--------------------------------------------------------------------------------
-- Small helpers
--------------------------------------------------------------------------------

local function rarityColor(rarity: string?): Color3
	local color = if rarity ~= nil then (RarityTable.RARITY_COLORS :: any)[rarity] else nil
	if typeof(color) == "Color3" then
		return color
	end
	return COLOR_FALLBACK
end

local function tierColor(tier: number): Color3
	return rarityColor(TIER_COLOR_KEYS[tier])
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

local function makeSound(parent: Instance, name: string, soundId: string, looped: boolean): Sound
	local sound = Instance.new("Sound")
	sound.Name = name
	sound.SoundId = soundId
	sound.Looped = looped
	sound.Volume = 0.5
	sound.Parent = parent
	return sound
end

local function tween(instance: Instance, seconds: number, props: { [string]: any }, style: Enum.EasingStyle?): Tween
	local t = TweenService:Create(instance, TweenInfo.new(seconds, style or Enum.EasingStyle.Quad), props)
	t:Play()
	return t
end

--------------------------------------------------------------------------------
-- Viewport part construction (recipe spec, CONTRACTS §E)
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

local function destroyViewportModel(model: ViewportModel?)
	if model == nil then
		return
	end
	for _, part in model.parts do
		part:Destroy()
	end
	if model.container ~= nil then
		model.container:Destroy() -- also clears RarityFX dressing (rays/halo/loops)
		model.container = nil
	end
	table.clear(model.parts)
	table.clear(model.base)
end

-- Render scale of a def (collectible redesign: chase tiers render bigger).
local function defScale(def: any): number
	if type(def) == "table" and type(def.scale) == "number" and def.scale > 0 then
		return def.scale
	end
	return 1
end

-- Tallest rendered point of a recipe (def.scale applied), for camera framing.
local function recipeHeight(def: any): number
	local maxY = 2
	if type(def) == "table" and type(def.recipe) == "table" then
		for _, rp in def.recipe do
			local ok, top = pcall(function()
				return (rp.offset :: any).Y + (rp.size :: any).Y / 2
			end)
			if ok and type(top) == "number" then
				maxY = math.max(maxY, top * defScale(def))
			end
		end
	end
	return maxY
end

--------------------------------------------------------------------------------
-- GUI construction (lazy)
--------------------------------------------------------------------------------

local function updateScale()
	if ui == nil then
		return
	end
	local camera = workspace.CurrentCamera
	if camera == nil then
		return
	end
	local shortAxis = math.min(camera.ViewportSize.X, camera.ViewportSize.Y)
	if shortAxis > 0 then
		ui.scale.Scale = math.clamp(shortAxis / DESIGN_SHORT_AXIS_PX, UISCALE_MIN, UISCALE_MAX)
	end
end

-- Two crossed gradient frames fake a radial edge glow with zero image assets
-- (same trick as RunHUD's vignette) — this is the rarity flash.
local function makeEdgeFlash(parent: GuiObject, rotation: number): Frame
	local frame = Instance.new("Frame")
	frame.Name = `EdgeFlash{rotation}`
	frame.Size = UDim2.fromScale(1, 1)
	frame.BackgroundColor3 = COLOR_FALLBACK
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0
	frame.ZIndex = 2
	local gradient = Instance.new("UIGradient")
	gradient.Rotation = rotation
	gradient.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.05),
		NumberSequenceKeypoint.new(0.3, 1),
		NumberSequenceKeypoint.new(0.7, 1),
		NumberSequenceKeypoint.new(1, 0.05),
	})
	gradient.Parent = frame
	frame.Parent = parent
	return frame
end

local function buildGui()
	local gui = Instance.new("ScreenGui")
	gui.Name = "UnboxingUI"
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = false
	gui.ScreenInsets = Enum.ScreenInsets.DeviceSafeInsets
	gui.DisplayOrder = 20 -- above RunHUD (10), below OddsUI (24) and BroadcastUI (40)

	-- Theater root: everything that shows/hides as one unit.
	local theater = Instance.new("Frame")
	theater.Name = "Theater"
	theater.Size = UDim2.fromScale(1, 1)
	theater.BackgroundTransparency = 1
	theater.Visible = false
	theater.Parent = gui

	-- Dim: semi-transparent (confetti bursts in 3D must read through) and
	-- Active so taps don't leak into the world while the theater is up.
	local dim = Instance.new("Frame")
	dim.Name = "Dim"
	dim.Size = UDim2.fromScale(1, 1)
	dim.BackgroundColor3 = COLOR_DIM
	dim.BackgroundTransparency = 1
	dim.BorderSizePixel = 0
	dim.Active = true
	dim.ZIndex = 1
	dim.Parent = theater

	local flashH = makeEdgeFlash(theater, 0)
	local flashV = makeEdgeFlash(theater, 90)

	-- Gold beam rays (godly only), behind the viewport.
	local rays = Instance.new("Frame")
	rays.Name = "GoldRays"
	rays.AnchorPoint = Vector2.new(0.5, 0.5)
	rays.Position = UDim2.fromScale(0.5, 0.44)
	rays.Size = UDim2.fromOffset(0, 0)
	rays.BackgroundTransparency = 1
	rays.Visible = false
	rays.ZIndex = 3
	rays.Parent = theater

	-- Scaled root for all sized content (16:9-safe central column, §1.4:
	-- the reveal composition self-frames for vertical clips too).
	local root = Instance.new("Frame")
	root.Name = "Root"
	root.AnchorPoint = Vector2.new(0.5, 0.5)
	root.Position = UDim2.fromScale(0.5, 0.5)
	root.Size = UDim2.fromScale(1, 1)
	root.BackgroundTransparency = 1
	root.ZIndex = 4
	root.Parent = theater

	local scale = Instance.new("UIScale")
	scale.Parent = root

	-- The stage: a ViewportFrame holding the greybox case, then the Cryptling.
	local viewport = Instance.new("ViewportFrame")
	viewport.Name = "Stage"
	viewport.AnchorPoint = Vector2.new(0.5, 0.5)
	viewport.Position = UDim2.fromScale(0.5, 0.44)
	viewport.Size = UDim2.fromOffset(330, 300)
	viewport.BackgroundTransparency = 1
	viewport.Ambient = Color3.fromRGB(195, 195, 205)
	viewport.LightColor = Color3.fromRGB(255, 252, 244)
	viewport.LightDirection = Vector3.new(-0.4, -1, 0.6)
	viewport.ZIndex = 4
	viewport.Parent = root

	local camera = Instance.new("Camera")
	camera.FieldOfView = 50
	camera.Parent = viewport
	viewport.CurrentCamera = camera

	-- Peel strip: the drag gesture surface, overlaid on the case top.
	local strip = Instance.new("Frame")
	strip.Name = "PeelStrip"
	strip.AnchorPoint = Vector2.new(0.5, 0.5)
	strip.Position = UDim2.new(0.5, 0, 0.44, -96)
	strip.Size = UDim2.fromOffset(STRIP_WIDTH_PX, STRIP_HEIGHT_PX)
	strip.BackgroundColor3 = COLOR_PANEL
	strip.BackgroundTransparency = 0.45
	strip.BorderSizePixel = 0
	strip.Active = true -- sinks the touch so the gesture is the strip's alone
	strip.ZIndex = 6
	strip.Parent = root
	makeRound(strip, 14)

	local groove = Instance.new("Frame")
	groove.Name = "Groove"
	groove.AnchorPoint = Vector2.new(0.5, 0.5)
	groove.Position = UDim2.fromScale(0.5, 0.5)
	groove.Size = UDim2.new(1, -16, 0, 14)
	groove.BackgroundColor3 = Color3.fromRGB(40, 43, 50)
	groove.BorderSizePixel = 0
	groove.ZIndex = 6
	groove.Parent = strip
	makeRound(groove, 7)

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(0, 1)
	fill.BackgroundColor3 = COLOR_TAPE
	fill.BorderSizePixel = 0
	fill.ZIndex = 7
	fill.Parent = groove
	makeRound(fill, 7)

	local handle = Instance.new("Frame")
	handle.Name = "Handle"
	handle.AnchorPoint = Vector2.new(0, 0.5)
	handle.Position = UDim2.new(0, 4, 0.5, 0)
	handle.Size = UDim2.fromOffset(HANDLE_PX, HANDLE_PX)
	handle.BackgroundColor3 = COLOR_TAPE
	handle.BorderSizePixel = 0
	handle.ZIndex = 8
	handle.Parent = strip
	local handleCorner = Instance.new("UICorner")
	handleCorner.CornerRadius = UDim.new(1, 0)
	handleCorner.Parent = handle

	local handleGlyph = makeLabel("Glyph", 22, true)
	handleGlyph.Size = UDim2.fromScale(1, 1)
	handleGlyph.TextColor3 = COLOR_PANEL
	handleGlyph.Text = ">>"
	handleGlyph.ZIndex = 9
	handleGlyph.Parent = handle

	local hint = makeLabel("PeelHint", 15, true)
	hint.AnchorPoint = Vector2.new(0.5, 0.5)
	hint.Position = UDim2.new(0.5, 0, 0.44, -142)
	hint.Size = UDim2.fromOffset(280, 20)
	hint.Text = "DRAG TO PEEL"
	hint.ZIndex = 6
	hint.Parent = root

	-- Cancel (peel phase only) — backing out before commit costs nothing.
	local cancel = Instance.new("TextButton")
	cancel.Name = "Cancel"
	cancel.AnchorPoint = Vector2.new(1, 0)
	cancel.Position = UDim2.new(1, -12, 0, 12)
	cancel.Size = UDim2.fromOffset(CANCEL_PX, CANCEL_PX)
	cancel.BackgroundColor3 = COLOR_PANEL
	cancel.BackgroundTransparency = 0.25
	cancel.BorderSizePixel = 0
	cancel.Font = Enum.Font.GothamBold
	cancel.TextSize = 20
	cancel.TextColor3 = COLOR_TEXT_DIM
	cancel.Text = "X"
	cancel.ZIndex = 7
	cancel.Parent = root
	makeRound(cancel, 12)

	-- Name card (reveal phase).
	local card = Instance.new("Frame")
	card.Name = "NameCard"
	card.AnchorPoint = Vector2.new(0.5, 0)
	card.Position = UDim2.new(0.5, 0, 0.44, 118)
	card.Size = UDim2.fromOffset(300, 112)
	card.BackgroundColor3 = COLOR_PANEL
	card.BackgroundTransparency = 0.12
	card.BorderSizePixel = 0
	card.Visible = false
	card.ZIndex = 6
	card.Parent = root
	makeRound(card, 12)
	local cardStroke = Instance.new("UIStroke")
	cardStroke.Thickness = 2
	cardStroke.Color = COLOR_FALLBACK
	cardStroke.Parent = card

	local nameLabel = makeLabel("CryptlingName", 24, true)
	nameLabel.Position = UDim2.fromOffset(0, 8)
	nameLabel.Size = UDim2.new(1, 0, 0, 28)
	nameLabel.ZIndex = 7
	nameLabel.Parent = card

	local rarityLabel = makeLabel("Rarity", 14, true)
	rarityLabel.Position = UDim2.fromOffset(0, 38)
	rarityLabel.Size = UDim2.new(1, 0, 0, 18)
	rarityLabel.ZIndex = 7
	rarityLabel.Parent = card

	-- Epithet sub-line (collectible redesign): the def's flavor one-liner,
	-- kept subtle under the rarity row.
	local epithetLabel = makeLabel("Epithet", 12, false)
	epithetLabel.Position = UDim2.fromOffset(0, 56)
	epithetLabel.Size = UDim2.new(1, 0, 0, 14)
	epithetLabel.TextColor3 = COLOR_TEXT_DIM
	epithetLabel.Text = ""
	epithetLabel.Visible = false
	epithetLabel.ZIndex = 7
	epithetLabel.Parent = card

	local dupTag = makeLabel("DuplicateTag", 12, false)
	dupTag.Position = UDim2.fromOffset(0, 76)
	dupTag.Size = UDim2.new(1, 0, 0, 16)
	dupTag.TextColor3 = COLOR_GOLD
	dupTag.Text = "DUPLICATE — trade it at the swap meet"
	dupTag.Visible = false
	dupTag.ZIndex = 7
	dupTag.Parent = card

	-- Continue button (reveal phase).
	local continueButton = Instance.new("TextButton")
	continueButton.Name = "Continue"
	-- Sits just under the NameCard. (Anchoring to the scaled root's bottom
	-- edge pushed it off-screen whenever ui.scale > 1 — the scaled full-screen
	-- root overflows the viewport — leaving the reveal with no visible dismiss.)
	continueButton.AnchorPoint = Vector2.new(0.5, 0)
	continueButton.Position = UDim2.new(0.5, 0, 0.44, 118 + 112 + 22)
	continueButton.Size = UDim2.fromOffset(230, CONTINUE_HEIGHT_PX)
	continueButton.BackgroundColor3 = Color3.fromRGB(70, 160, 90)
	continueButton.BorderSizePixel = 0
	continueButton.Font = Enum.Font.GothamBold
	continueButton.TextSize = 18
	continueButton.TextColor3 = COLOR_TEXT
	continueButton.Text = "TAP TO CONTINUE"
	continueButton.Visible = false
	continueButton.ZIndex = 7
	continueButton.Parent = root
	makeRound(continueButton, 12)

	-- Odds popup: pinned under the case while the theater is open so the
	-- active tier's EXACT odds (server GetOddsTable, §8.1) are visible before
	-- the peel commits. The reveal NameCard takes this same slot afterwards.
	local oddsFrame = Instance.new("Frame")
	oddsFrame.Name = "TierOdds"
	oddsFrame.AnchorPoint = Vector2.new(0.5, 0)
	oddsFrame.Position = UDim2.new(0.5, 0, 0.44, 118)
	oddsFrame.Size = UDim2.fromOffset(280, 196)
	oddsFrame.BackgroundColor3 = COLOR_PANEL
	oddsFrame.BackgroundTransparency = 0.2
	oddsFrame.BorderSizePixel = 0
	oddsFrame.Visible = false
	oddsFrame.ZIndex = 6
	oddsFrame.Parent = root
	makeRound(oddsFrame, 12)

	local oddsTitle = makeLabel("Title", 13, true)
	oddsTitle.Position = UDim2.fromOffset(0, 8)
	oddsTitle.Size = UDim2.new(1, 0, 0, 16)
	oddsTitle.ZIndex = 7
	oddsTitle.Parent = oddsFrame
	oddsTitleLabel = oddsTitle

	-- One row per rarity — ALL of them, Mythical included: its real odds stay
	-- on screen (§8.1 compliance — never hide the long shot).
	for index = 1, #RarityTable.RARITY_ORDER do
		local row = makeLabel(`Row{index}`, 13, false)
		row.Position = UDim2.fromOffset(0, 12 + index * 22)
		row.Size = UDim2.new(1, 0, 0, 20)
		row.ZIndex = 7
		row.Parent = oddsFrame
		table.insert(oddsRows, row)
	end
	oddsPanel = oddsFrame

	-- Toast lives OUTSIDE the theater frame so it survives theater close
	-- (e.g. the NO_OPENS "locker's locked" message).
	local toast = Instance.new("Frame")
	toast.Name = "Toast"
	toast.AnchorPoint = Vector2.new(0.5, 1)
	toast.Position = UDim2.new(0.5, 0, 1, -86)
	toast.Size = UDim2.fromOffset(280, 44)
	toast.BackgroundColor3 = COLOR_PANEL
	toast.BackgroundTransparency = 0.15
	toast.BorderSizePixel = 0
	toast.Visible = false
	toast.ZIndex = 10
	toast.Parent = gui
	makeRound(toast, 10)

	local toastLabel = makeLabel("Text", 15, true)
	toastLabel.Size = UDim2.new(1, -12, 1, 0)
	toastLabel.Position = UDim2.fromOffset(6, 0)
	toastLabel.TextWrapped = true
	toastLabel.ZIndex = 11
	toastLabel.Parent = toast

	-- Theater sounds.
	local rumble = makeSound(gui, "PeelRumble", SOUND_THUMP, true)
	rumble.Volume = 0
	local tick = makeSound(gui, "PeelTick", SOUND_TICK, false)
	local thump = makeSound(gui, "SuspenseThump", SOUND_THUMP, false)
	local snap = makeSound(gui, "AssembleSnap", SOUND_SNAP, false)
	local fanfare = makeSound(gui, "RevealFanfare", SOUND_FANFARE, false)

	ui = {
		gui = gui,
		theater = theater,
		dim = dim,
		flashH = flashH,
		flashV = flashV,
		rays = rays,
		root = root,
		scale = scale,
		viewport = viewport,
		camera = camera,
		strip = strip,
		fill = fill,
		handle = handle,
		hint = hint,
		cancel = cancel,
		card = card,
		cardStroke = cardStroke,
		nameLabel = nameLabel,
		rarityLabel = rarityLabel,
		epithetLabel = epithetLabel,
		dupTag = dupTag,
		continueButton = continueButton,
		toast = toast,
		toastLabel = toastLabel,
		rumble = rumble,
		tick = tick,
		thump = thump,
		snap = snap,
		fanfare = fanfare,
	}

	gui.Parent = LocalPlayer:WaitForChild("PlayerGui")
	updateScale()
	local currentCamera = workspace.CurrentCamera
	if currentCamera ~= nil then
		currentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(updateScale)
	end
end

--------------------------------------------------------------------------------
-- Toast
--------------------------------------------------------------------------------

local function showToast(text: string, seconds: number?)
	if ui == nil then
		return
	end
	toastToken += 1
	local token = toastToken
	ui.toastLabel.Text = text
	ui.toast.Visible = true
	task.delay(seconds or 4, function()
		if toastToken == token and ui ~= nil then
			ui.toast.Visible = false
		end
	end)
end

--------------------------------------------------------------------------------
-- Case + Cryptling staging in the viewport
--------------------------------------------------------------------------------

local CASE_CAMERA_CF = CFrame.lookAt(Vector3.new(0, 2.6, -7.4), Vector3.new(0, 1.4, 0))

local function buildCaseModel(tier: number)
	destroyViewportModel(caseModel)
	destroyViewportModel(revealModel)
	revealModel = nil

	local color = tierColor(tier)
	local model: ViewportModel = { parts = {}, base = {} }

	local function add(part: BasePart)
		table.insert(model.parts, part)
		table.insert(model.base, part.CFrame)
		part.Parent = ui.viewport
	end

	-- Pedestal (Cylinder height runs along X — rotate upright).
	add(
		makeGreyboxPart(
			"Cylinder",
			Vector3.new(0.9, 4.6, 4.6),
			CFrame.new(0, -0.45, 0) * CFrame.Angles(0, 0, math.rad(90)),
			COLOR_PEDESTAL
		)
	)
	-- Case body + lid.
	add(makeGreyboxPart("Block", Vector3.new(3, 2.1, 2.4), CFrame.new(0, 1.05, 0), color))
	local lid = makeGreyboxPart(
		"Block",
		Vector3.new(3.2, 0.45, 2.6),
		CFrame.new(0, 2.35, 0),
		color:Lerp(Color3.new(0, 0, 0), 0.25)
	)
	add(lid)
	-- Tape strip across the case top — the 3D mirror of the 2D peel gesture.
	local tape = makeGreyboxPart("Block", Vector3.new(3.3, 0.12, 0.7), CFrame.new(0, 2.62, 0), COLOR_TAPE)
	tape.Material = Enum.Material.Neon
	add(tape)

	caseModel = model
	caseLid = lid
	caseTape = tape
	caseTapeBase = tape.CFrame
	caseTapeWidth = tape.Size.X
	ui.camera.CFrame = CASE_CAMERA_CF
	ui.camera.FieldOfView = 50
end

local function buildCryptlingModel(def: any, fallbackColor: Color3)
	destroyViewportModel(revealModel)
	local container = Instance.new("Model")
	container.Name = "RevealCryptling"
	container.Parent = ui.viewport
	local model: ViewportModel = { parts = {}, base = {}, container = container }
	revealModel = model

	if type(def) ~= "table" or type(def.recipe) ~= "table" then
		-- Unknown id: a lone greybox ball still gives the moment a body.
		local part = makeGreyboxPart("Ball", Vector3.new(2, 2, 2), CFrame.new(0, 1, 0), fallbackColor)
		table.insert(model.parts, part)
		table.insert(model.base, part.CFrame)
		part.Parent = container
		return
	end

	local baseColor: Color3 = if typeof(def.color) == "Color3" then def.color else fallbackColor
	local scale = defScale(def)
	for _, rp in def.recipe do
		local color: Color3 = if typeof(rp.colorOverride) == "Color3" then rp.colorOverride else baseColor
		local offset = rp.offset :: CFrame
		local part = makeGreyboxPart(
			rp.shape,
			(rp.size :: Vector3) * scale,
			CFrame.new(offset.Position * scale) * offset.Rotation,
			color
		)
		table.insert(model.parts, part)
		table.insert(model.base, part.CFrame)
		-- NOT parented yet — assembly parents them one by one for the
		-- "built live on the line" beat.
	end
end

-- Shake/spin both re-derive from authored base CFrames each frame.
local function transformModel(model: ViewportModel?, transform: CFrame)
	if model == nil then
		return
	end
	for index, part in model.parts do
		part.CFrame = transform * model.base[index]
	end
end

--------------------------------------------------------------------------------
-- Peel phase
--------------------------------------------------------------------------------

local function setPeelVisuals(progress: number)
	ui.fill.Size = UDim2.fromScale(progress, 1)
	local travel = STRIP_WIDTH_PX - HANDLE_PX - 8
	ui.handle.Position = UDim2.new(0, 4 + travel * progress, 0.5, 0)
	-- Handle past the commit line glows tier-gold as a "let go!" cue.
	ui.handle.BackgroundColor3 = if progress >= PEEL_COMMIT_FRACTION then COLOR_GOLD else COLOR_TAPE

	-- 3D tape shrinks from the left as it peels off.
	local tape = caseTape
	local tapeBase = caseTapeBase
	if tape ~= nil and tapeBase ~= nil then
		local remaining = math.max(caseTapeWidth * (1 - progress), 0.05)
		tape.Size = Vector3.new(remaining, tape.Size.Y, tape.Size.Z)
		tape.CFrame = tapeBase * CFrame.new(caseTapeWidth * progress / 2, 0, 0)
	end
end

local function stepPeel(deltaTime: number)
	-- Resistance easing: the strip gets heavier the further it's pulled.
	local rate: number
	if dragging then
		rate = PEEL_MAX_RATE * (1 - PEEL_RESISTANCE * peelProgress)
	else
		rate = PEEL_RETURN_RATE
	end
	local delta = dragTarget - peelProgress
	local step = math.clamp(delta, -rate * deltaTime, rate * deltaTime)
	peelProgress = math.clamp(peelProgress + step, 0, 1)

	setPeelVisuals(peelProgress)

	-- Haptic-style shake: the case rattles harder as the tape gives way.
	local amplitude = peelProgress * 0.1
	transformModel(
		caseModel,
		CFrame.new((math.random() - 0.5) * amplitude * 2, (math.random() - 0.5) * amplitude, 0)
			* CFrame.Angles(0, (math.random() - 0.5) * amplitude * 0.5, 0)
	)
	ui.handle.Rotation = (math.random() - 0.5) * 10 * peelProgress

	-- Rising audio: a swelling rumble plus quickening ticks.
	ui.rumble.Volume = 0.45 * peelProgress
	ui.rumble.PlaybackSpeed = 0.5 + 0.5 * peelProgress
	if peelProgress - lastTickProgress >= 0.07 then
		lastTickProgress = peelProgress
		ui.tick.PlaybackSpeed = 0.7 + peelProgress
		ui.tick.Volume = 0.2 + 0.4 * peelProgress
		ui.tick:Play()
	elseif peelProgress < lastTickProgress then
		lastTickProgress = peelProgress
	end
end

local function onStripInputBegan(input: InputObject)
	if phase ~= "Peel" or dragging then
		return
	end
	if input.UserInputType ~= Enum.UserInputType.Touch and input.UserInputType ~= Enum.UserInputType.MouseButton1 then
		return
	end
	dragging = true
	dragInput = input
	lastDragX = input.Position.X
end

local function onGlobalInputChanged(input: InputObject)
	if not dragging or phase ~= "Peel" then
		return
	end
	local isThisTouch = input == dragInput
	local isMouseMove = dragInput ~= nil
		and (dragInput :: InputObject).UserInputType == Enum.UserInputType.MouseButton1
		and input.UserInputType == Enum.UserInputType.MouseMovement
	if not isThisTouch and not isMouseMove then
		return
	end
	local deltaX = input.Position.X - lastDragX
	lastDragX = input.Position.X
	-- Drag distance is measured in unscaled px against the scaled strip width.
	local scaledWidth = STRIP_WIDTH_PX * ui.scale.Scale
	dragAccumPx = math.clamp(dragAccumPx + deltaX, 0, scaledWidth * 1.05)
	dragTarget = dragAccumPx / (scaledWidth * 1.02)
end

local function onGlobalInputEnded(input: InputObject)
	if not dragging then
		return
	end
	local isThisTouch = input == dragInput
	local isMouseUp = input.UserInputType == Enum.UserInputType.MouseButton1
	if not isThisTouch and not isMouseUp then
		return
	end
	dragging = false
	dragInput = nil
	if peelProgress >= PEEL_COMMIT_FRACTION then
		committed = true -- release past 90% -> the case opens (spec)
	else
		-- Spring back: the chase loop returns progress to 0 at PEEL_RETURN_RATE.
		dragAccumPx = 0
		dragTarget = 0
	end
end

-- Yields until the peel commits or the player cancels. Returns committed.
local function runPeelPhase(): boolean
	phase = "Peel"
	peelProgress = 0
	dragTarget = 0
	dragAccumPx = 0
	dragging = false
	dragInput = nil
	committed = false
	cancelRequested = false
	lastTickProgress = 0
	setPeelVisuals(0)
	ui.rumble:Play()

	local heartbeat = RunService.Heartbeat:Connect(stepPeel)
	while not committed and not cancelRequested do
		if peelProgress >= 0.995 then
			committed = true -- dragged clean off the end: no release needed
		else
			task.wait()
		end
	end
	heartbeat:Disconnect()

	dragging = false
	dragInput = nil
	ui.rumble:Stop()
	transformModel(caseModel, CFrame.identity)
	if committed then
		setPeelVisuals(1)
	end
	return committed
end

--------------------------------------------------------------------------------
-- Open request (guarded so a missing/slow server can never hang the theater)
--------------------------------------------------------------------------------

local function requestOpenCase(caseUid: string): any
	local response: any = nil
	local done = false
	task.spawn(function()
		local ok, result = pcall(function()
			return Remotes.GetFunction("RequestOpenCase"):InvokeServer(caseUid)
		end)
		if ok then
			response = result
		end
		done = true
	end)

	-- Suspense beat overlaps server latency: 0.8s heartbeat, dim pulse.
	phase = "Suspense"
	tween(ui.dim, 0.2, { BackgroundTransparency = DIM_TRANSPARENCY - 0.15 })
	for beat = 1, 2 do
		ui.thump.PlaybackSpeed = 0.55
		ui.thump.Volume = 0.5 + 0.2 * beat
		ui.thump:Play()
		task.wait(SUSPENSE_SECONDS / 2)
	end
	tween(ui.dim, 0.2, { BackgroundTransparency = DIM_TRANSPARENCY })

	local deadline = os.clock() + OPEN_RESPONSE_TIMEOUT_SECONDS
	while not done and os.clock() < deadline do
		task.wait(0.05)
	end
	if not done or type(response) ~= "table" then
		return { ok = false, err = "TIMEOUT" }
	end
	return response
end

--------------------------------------------------------------------------------
-- Reveal effects
--------------------------------------------------------------------------------

local function flashEdges(color: Color3)
	for _, frame in { ui.flashH, ui.flashV } do
		frame.BackgroundColor3 = color
		frame.BackgroundTransparency = 1
		tween(frame, 0.12, { BackgroundTransparency = 0.15 }, Enum.EasingStyle.Quint)
	end
	task.delay(0.25, function()
		if ui ~= nil then
			tween(ui.flashH, 0.7, { BackgroundTransparency = 1 })
			tween(ui.flashV, 0.7, { BackgroundTransparency = 1 })
		end
	end)
end

-- Confetti burst on a stage anchor part in front of the live camera. Parts
-- parented under the Camera render locally and never replicate — perfect for
-- per-player theater dressing.
local function spawnConfetti(rarity: string, color: Color3)
	local camera = workspace.CurrentCamera
	if camera == nil then
		return
	end
	local count = CONFETTI_COUNT[rarity] or CONFETTI_COUNT.Common
	local seconds = CONFETTI_SECONDS[rarity] or CONFETTI_SECONDS.Common

	local anchor = Instance.new("Part")
	anchor.Name = "UnboxStageAnchor"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(4, 1, 1)
	anchor.CFrame = camera.CFrame * CFrame.new(0, -3, -9)

	local function makeEmitter(emitterColor: ColorSequence): ParticleEmitter
		local emitter = Instance.new("ParticleEmitter")
		emitter.Enabled = false
		emitter.Color = emitterColor
		emitter.Lifetime = NumberRange.new(0.8, seconds)
		emitter.Speed = NumberRange.new(22, 34)
		emitter.SpreadAngle = Vector2.new(55, 55)
		emitter.Rotation = NumberRange.new(0, 360)
		emitter.RotSpeed = NumberRange.new(-260, 260)
		emitter.Acceleration = Vector3.new(0, -36, 0)
		emitter.Drag = 1
		emitter.Size = NumberSequence.new(0.32)
		emitter.EmissionDirection = Enum.NormalId.Top
		emitter.Parent = anchor
		return emitter
	end

	-- Party mix + a second emitter in the pulled rarity's color.
	local partyMix = makeEmitter(ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 105, 120)),
		ColorSequenceKeypoint.new(0.33, Color3.fromRGB(120, 200, 255)),
		ColorSequenceKeypoint.new(0.66, Color3.fromRGB(140, 230, 130)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(250, 220, 110)),
	}))
	local rarityBurst = makeEmitter(ColorSequence.new(color))

	anchor.Parent = camera
	partyMix:Emit(math.floor(count * 0.6))
	rarityBurst:Emit(math.ceil(count * 0.4))
	task.delay(seconds + 2, function()
		anchor:Destroy()
	end)
end

-- Godly extras: screen gold beams + slow-mo FOV punch on the live camera.
local function playGodlyExtras()
	local rays = ui.rays
	rays.Visible = true
	for index = 1, 6 do
		local ray = Instance.new("Frame")
		ray.Name = `Ray{index}`
		ray.AnchorPoint = Vector2.new(0.5, 0.5)
		ray.Position = UDim2.fromScale(0.5, 0.5)
		ray.Size = UDim2.fromOffset(1400, 26)
		ray.BackgroundColor3 = COLOR_GOLD
		ray.BackgroundTransparency = 0.45
		ray.BorderSizePixel = 0
		ray.Rotation = index * 30
		ray.ZIndex = 3
		local gradient = Instance.new("UIGradient")
		gradient.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.5, 0.1),
			NumberSequenceKeypoint.new(1, 1),
		})
		gradient.Parent = ray
		ray.Parent = rays
		tween(ray, 1.6, { Rotation = ray.Rotation + 28, BackgroundTransparency = 1 })
	end
	task.delay(1.7, function()
		if ui ~= nil then
			ui.rays.Visible = false
			for _, child in ui.rays:GetChildren() do
				child:Destroy()
			end
		end
	end)

	local camera = workspace.CurrentCamera
	if camera ~= nil then
		local baseFov = camera.FieldOfView
		-- Punch in fast, ease out slow: the "slow-mo" beat.
		local punch = TweenService:Create(
			camera,
			TweenInfo.new(0.16, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
			{ FieldOfView = math.max(baseFov - 16, 30) }
		)
		punch:Play()
		punch.Completed:Once(function()
			TweenService:Create(
				camera,
				TweenInfo.new(1.4, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
				{ FieldOfView = baseFov }
			):Play()
		end)
	end
end

-- Lid pop + live assembly from the RarityTable recipe, then the slow turntable.
local function revealCryptling(def: any, rarity: string, color: Color3, isDuplicate: boolean)
	phase = "Reveal"
	local pacing = REVEAL_PACING[rarity] or REVEAL_PACING.Rare

	flashEdges(color)
	spawnConfetti(rarity, color)
	if rarity == "Legendary" or rarity == "Godly" or rarity == "Mythical" then
		playGodlyExtras() -- the top-tier ray burst now covers Legendary and up
	end

	ui.fanfare.Volume = REVEAL_VOLUME[rarity] or 0.4
	ui.fanfare:Play()

	-- Lid pops off.
	local lid = caseLid
	if lid ~= nil then
		tween(
			lid,
			0.3,
			{ CFrame = lid.CFrame * CFrame.new(0.6, 5, 0) * CFrame.Angles(0, 0, math.rad(50)) },
			Enum.EasingStyle.Quint
		)
	end
	task.wait(0.3)
	destroyViewportModel(caseModel)
	caseModel = nil
	caseLid = nil
	caseTape = nil
	caseTapeBase = nil

	-- Reframe the camera for the Cryptling's height.
	local height = recipeHeight(def)
	local eye = Vector3.new(0, height * 0.62, -(height * 1.7 + 3.2))
	tween(ui.camera, 0.4, { CFrame = CFrame.lookAt(eye, Vector3.new(0, height * 0.48, 0)) })

	-- Assemble live, part by part, each with a snap tick.
	buildCryptlingModel(def, color)
	local model = revealModel
	if model ~= nil then
		for index, part in model.parts do
			part.Parent = model.container or ui.viewport
			ui.snap.PlaybackSpeed = 0.9 + index * 0.06
			ui.snap.Volume = 0.4
			ui.snap:Play()
			task.wait(pacing.assemble)
		end
		-- Tier signature, viewport-safe: static colors/lights only (tweens and
		-- emitters don't read well inside a ViewportFrame).
		if model.container ~= nil then
			RarityFX.Apply(model.container, def, { static = true })
		end
	end

	-- Name card.
	local displayName = if type(def) == "table" and type(def.name) == "string" then def.name else "???"
	ui.nameLabel.Text = displayName
	ui.rarityLabel.Text = (RarityTable.RARITY_DISPLAY :: any)[rarity] or string.upper(rarity)
	ui.rarityLabel.TextColor3 = color
	ui.cardStroke.Color = color
	local epithet = if type(def) == "table" and type(def.epithet) == "string" then def.epithet else nil
	ui.epithetLabel.Text = epithet or ""
	ui.epithetLabel.Visible = epithet ~= nil
	if oddsPanel ~= nil then
		oddsPanel.Visible = false -- the NameCard takes this slot now
	end
	ui.dupTag.Visible = isDuplicate
	ui.card.Visible = true
	ui.card.Size = UDim2.fromOffset(260, 98)
	tween(ui.card, 0.18, { Size = UDim2.fromOffset(300, 112) }, Enum.EasingStyle.Back)

	-- Slow turntable while the player soaks it in / records the clip.
	local angle = 0
	spinConnection = RunService.RenderStepped:Connect(function(deltaTime: number)
		angle += deltaTime * SPIN_RADIANS_PER_SECOND
		transformModel(revealModel, CFrame.Angles(0, angle, 0))
	end)

	continuePressed = false
	ui.continueButton.Visible = true
	local autoCloseAt = os.clock() + pacing.soak
	while not continuePressed and os.clock() < autoCloseAt do
		task.wait(0.05)
	end
end

--------------------------------------------------------------------------------
-- Theater open/close
--------------------------------------------------------------------------------

-- One-time gui construction + handler binding (lazy: first PlayOpen builds it,
-- keeping the join-to-playing path light per §G).
local function ensureGui()
	if ui ~= nil then
		return
	end
	buildGui()
	ui.strip.InputBegan:Connect(onStripInputBegan)
	ui.cancel.Activated:Connect(function()
		if phase == "Peel" then
			cancelRequested = true
		end
	end)
	ui.continueButton.Activated:Connect(function()
		continuePressed = true
	end)
end

local function setOddsContext(tier: number?)
	if oddsUI == nil then
		return
	end
	if tier ~= nil and type(oddsUI.SetContext) == "function" then
		oddsUI.SetContext("theater", tier)
	elseif tier == nil and type(oddsUI.ClearContext) == "function" then
		oddsUI.ClearContext("theater")
	end
end

-- Fills the under-case odds popup from the server's GetOddsTable (the §8.1
-- single source of truth). Async; a stale reply (token mismatch) is dropped.
local function showTierOdds(tier: number)
	local panel = oddsPanel
	if panel == nil then
		return
	end
	oddsToken += 1
	local token = oddsToken
	if oddsTitleLabel ~= nil then
		oddsTitleLabel.Text = `TIER {tier} CASE ODDS`
	end
	for _, row in oddsRows do
		row.Text = ""
	end
	panel.Visible = true
	task.spawn(function()
		local ok, odds = pcall(function()
			return Remotes.GetFunction("GetOddsTable"):InvokeServer(tier)
		end)
		if not ok or token ~= oddsToken or type(odds) ~= "table" then
			return
		end
		for index, row in odds :: { any } do
			local label = oddsRows[index]
			if label ~= nil and type(row) == "table" then
				local display = (RarityTable.RARITY_DISPLAY :: any)[row.rarity] or tostring(row.rarity)
				-- %g keeps tiny odds honest ("0.001%"), never rounded to 0.
				label.Text = string.format("%s  —  %g%%", tostring(display), row.pct)
				label.TextColor3 = rarityColor(row.rarity)
			end
		end
	end)
end

local function openTheater(tier: number)
	setCursorReleased(true)
	ensureGui()
	buildCaseModel(tier)
	ui.card.Visible = false
	ui.dupTag.Visible = false
	ui.continueButton.Visible = false
	showTierOdds(tier)
	ui.strip.Visible = true
	ui.hint.Visible = true
	ui.cancel.Visible = true
	ui.dim.BackgroundTransparency = 1
	ui.theater.Visible = true
	tween(ui.dim, 0.25, { BackgroundTransparency = DIM_TRANSPARENCY })
	setOddsContext(tier)
end

local function closeTheater()
	setCursorReleased(false)
	phase = "Idle"
	if spinConnection ~= nil then
		spinConnection:Disconnect()
		spinConnection = nil
	end
	if ui ~= nil then
		ui.rumble:Stop()
		ui.theater.Visible = false
	end
	if oddsPanel ~= nil then
		oddsPanel.Visible = false
	end
	destroyViewportModel(caseModel)
	destroyViewportModel(revealModel)
	caseModel = nil
	revealModel = nil
	caseLid = nil
	caseTape = nil
	caseTapeBase = nil
	setOddsContext(nil)
end

-- NO_OPENS copy: "locker's locked — N opens tomorrow", N = the player's daily
-- allowance (VIP-aware via GetLockerState, falling back to the §G default).
local function lockerLockedText(): string
	local opensPerDay = GameConstants.FREE_OPENS_PER_DAY
	local done = false
	task.spawn(function()
		local ok, state = pcall(function()
			return Remotes.GetFunction("GetLockerState"):InvokeServer()
		end)
		if ok and type(state) == "table" and type(state.opensPerDay) == "number" then
			opensPerDay = state.opensPerDay
		end
		done = true
	end)
	local deadline = os.clock() + 2
	while not done and os.clock() < deadline do
		task.wait(0.05)
	end
	return `Locker's locked — {opensPerDay} opens tomorrow`
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

function UnboxingUI.IsBusy(): boolean
	return busy
end

-- The whole theater, start to finish. Yields; returns the RequestOpenCase
-- response (or a client-side {ok=false, err=...}). Stage 3 LockerUI calls this
-- per case via Controllers.Get("UnboxingUI").PlayOpen(caseStub).
function UnboxingUI.PlayOpen(caseStub: any): any
	if busy then
		return { ok = false, err = "BUSY" }
	end
	if
		type(caseStub) ~= "table"
		or type(caseStub.uid) ~= "string"
		or type(caseStub.tier) ~= "number"
		or caseStub.tier < 1
		or caseStub.tier > 6 -- tier 6 = the rainbow box (Legendary and up)
	then
		return { ok = false, err = "BAD_STUB" }
	end

	busy = true
	local ok, result = pcall(function()
		openTheater(caseStub.tier)

		if not runPeelPhase() then
			closeTheater()
			return { ok = false, err = "CANCELLED" }
		end

		-- Commit: strip fades, the server rolls (ALL rolls server-side, §E).
		ui.strip.Visible = false
		ui.hint.Visible = false
		ui.cancel.Visible = false
		local response = requestOpenCase(caseStub.uid)

		if response.ok == true and type(response.cryptlingId) == "string" then
			local def = RarityTable.GetCryptling(response.cryptlingId)
			local rarity: string = if type(response.rarity) == "string"
				then response.rarity
				elseif type(def) == "table" then def.rarity
				else "Common"
			revealCryptling(def, rarity, rarityColor(rarity), response.isDuplicate == true)
			closeTheater()
		else
			closeTheater()
			local err = response.err
			if err == "NO_OPENS" then
				showToast(lockerLockedText(), 5)
			elseif err == "TIMEOUT" then
				showToast("The foreman's checking the manifest — try again in a moment", 4)
			elseif err == "NOT_OWNED" then
				showToast("That case isn't in your locker", 4)
			elseif err == "IN_TRADE" then
				showToast("That case is in your trade offer — remove it from the trade first", 4)
			else
				showToast("The case jammed — try again", 4)
			end
		end
		return response
	end)
	busy = false
	if not ok then
		closeTheater()
		warn(`[UnboxingUI] PlayOpen failed: {result}`)
		return { ok = false, err = "CLIENT_ERROR" }
	end
	return result
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function UnboxingUI:Init(registry: any)
	registryRef = registry
end

function UnboxingUI:Start()
	if registryRef ~= nil and type(registryRef.Get) == "function" then
		oddsUI = registryRef.Get("OddsUI")
	end

	-- Global input tracking for the drag gesture (begin is strip-scoped; move
	-- and release must keep working when the finger wanders off the strip).
	UserInputService.InputChanged:Connect(onGlobalInputChanged)
	UserInputService.InputEnded:Connect(onGlobalInputEnded)
end

return UnboxingUI
