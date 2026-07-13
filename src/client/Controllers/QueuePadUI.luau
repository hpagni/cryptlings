--!strict
-- CRYPTLINGS: NIGHT SHIFT — QueuePadUI (R2 WP5.3; LOBBY_SOP_ADDENDUM Change 6).
-- The client face of the metronome queue pad. The 45 s cycle NEVER pauses or
-- resets (Change 6.1.1), so the countdown is rendered LOCALLY from the
-- server-set ShiftEpoch attribute with zero per-second remotes:
--   remaining = CYCLE - (GetServerTimeNow() - epoch) % CYCLE
--
--   * ON-PAD CARD — while the LOCAL player is in the pad snapshot (QueueState
--     RemoteEvent payload, contract §B — same schema as round 1):
--     "NEXT SHIFT 0:NN — CLOCKED IN: n" over [Leave] / [Start now]
--     (>= 44 px touch targets, bottom-center, above the mobile thumb zones).
--     Leave stays ENABLED through T=0 — stepping off always works; only late
--     ENTRY locks at T-3 (Change 6.1.3). Start now fires the Queue.SetReady
--     unanimous vote (shows "Ready ✓" while cast; never moves the epoch).
--   * DOORS CLOSING — final FREEZE_SECONDS (3 s): card line flips to
--     "DOORS CLOSING", ring rim-flashes white, mirrored off the DoorsClosing
--     attribute (local epoch math as the fallback so the treatment still
--     lands when the attribute write races the final tick).
--   * DISPATCH FLASH — on epoch rollover with workers aboard: brief green
--     ring flash + one-shot toast "SHIFT STARTED — N FLOORS RUNNING" from the
--     ActiveFloors attribute (matches the billboard DISPATCH state).
--   * DEFERRAL TOAST — snapshot member still aboard after rollover with all
--     floor slots busy: "ALL FLOORS RUNNING" (that bin alone waits — Change
--     6.2.3); the master clock is already counting the next cycle.
--   * AFK TOAST — "Clocked out — inactive" when the server drops the local
--     player from the snapshot for inactivity (additive afkUserIds payload
--     field when present; mid-cycle removal while still standing on the pad
--     without a local Leave press as the heuristic fallback).
--   * RING TINT — tints/pulses the pad's Neon ring parts client-side off the
--     RingState attribute mirror (server owns the state, client owns every
--     tween — addendum standing invariant), QueueState/QueueCount attrs and
--     the last payload as fallbacks: idle = cyan slow pulse, workers aboard =
--     amber, full bin = green, doors-closing = white rim flash.
--   * ARROW BOUNCE — bounce-tweens QueuePadBuilder's "ClockInArrow" part
--     ±QUEUE_ARROW_BOUNCE_STUDS on a looping Sine tween (SOP §6.1).
--
-- RETIRED by the metronome (Change 6): the overflow card (everyone
-- dispatches — bins of 4, nobody waits full), the T-1 lock button disable
-- (leaving works at any time), and every legacy full-clamp/lock-at/re-arm
-- queue constant (superseded by LobbyConfig.DISPATCH — WP6.2 removes them).
--
-- All decisions are server-side (QueuePadService): this controller renders
-- mirrors and fires Queue.Leave / Queue.SetReady — it grants nothing.
-- Streaming-safe: the pad model (NightShiftHub.QueuePad, Atomic) is
-- re-resolved whenever the bound instance leaves the Workspace.
-- ONE Heartbeat loop drives countdown text, ring animation, rollover
-- detection, and pad re-binding (throttled) — zero per-part connections.
--
-- Public API (Controllers.Get("QueuePadUI")):
--   QueuePadUI.IsQueued() -> boolean  -- local player in the current snapshot

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local LobbyConfig = require(Shared:WaitForChild("Config"):WaitForChild("LobbyConfig"))
local Remotes = require(Shared:WaitForChild("Net"):WaitForChild("Remotes"))

local LocalPlayer = Players.LocalPlayer

--------------------------------------------------------------------------------
-- Tuning (cosmetic, this module's domain — dispatch numbers stay in
-- LobbyConfig.DISPATCH, the metronome constants of record)
--------------------------------------------------------------------------------

-- Metronome constants of record (Addendum 1 Change 6; never literals here).
local CYCLE_SECONDS = LobbyConfig.DISPATCH.CYCLE_SECONDS
local FREEZE_SECONDS = LobbyConfig.DISPATCH.FREEZE_SECONDS
local SLOT_COUNT = LobbyConfig.DISPATCH.SLOT_COUNT

-- Pad geometry contract (QueuePadBuilder names; hub model name preserved by
-- the HubService rewrite — LOBBY_BUILD_PLAN contract table).
local HUB_MODEL_NAME = "NightShiftHub"
local PAD_MODEL_NAME = "QueuePad"
local PAD_PART_NAME = "QueuePad"
local RING_PART_NAME = "QueueRing"
local ARROW_PART_NAME = "ClockInArrow"
local ZONE_PART_NAME = "ClockInZone"

-- Pad attribute mirror (QueuePadService WP5.1 — display data only). Names
-- QueueState/QueueCount/CountdownEndsAt survive from round 1 (the QueueState
-- attribute liveness contract is consumed server-side by getActiveQueuePad;
-- this client no longer keys off state strings — membership + RingState/
-- DoorsClosing/ShiftEpoch carry every treatment). ShiftEpoch/ActiveFloors/
-- DoorsClosing are the R2 additions.
local ATTR_QUEUE_COUNT = "QueueCount"
local ATTR_COUNTDOWN_ENDS_AT = "CountdownEndsAt"
local ATTR_SHIFT_EPOCH = "ShiftEpoch"
local ATTR_ACTIVE_FLOORS = "ActiveFloors"
local ATTR_DOORS_CLOSING = "DoorsClosing"
local ATTR_RING_STATE = "RingState"

local REBIND_SECONDS = 1 -- pad re-resolve cadence while unbound/stale
local ZONE_MARGIN_STUDS = 1.5 -- forgiving edge for the on-pad check

local DESIGN_SHORT_AXIS_PX = 450 -- same mobile scaling model as CountdownUI/RunHUD
local UISCALE_MIN = 0.85
local UISCALE_MAX = 1.6

local CARD_WIDTH_PX = 340
local CARD_HEIGHT_PX = 108
local CARD_BOTTOM_PX = 170 -- bottom-center, above RunHUD (-86) / CountdownUI (-132) toasts
local BUTTON_WIDTH_PX = 150
local BUTTON_HEIGHT_PX = 48 -- >= 44 px touch target (SOP §3.2 mobile-first)
local TOAST_WIDTH_PX = 300
local TOAST_HEIGHT_PX = 40
local TOAST_BOTTOM_PX = CARD_BOTTOM_PX + CARD_HEIGHT_PX + 10 -- clears the card
local TOAST_SECONDS = 4

local IDLE_PULSE_PERIOD_SECONDS = 2 -- "idle = cyan slow pulse" (SOP §6.1)
local STROBE_HZ = 8 -- white rim-flash square wave, DOORS CLOSING window
local STROBE_TRANSPARENCY_ON = 0.05
local STROBE_TRANSPARENCY_OFF = 0.65
local RING_STEADY_TRANSPARENCY = 0.35
local RING_LERP_PER_SECOND = 8 -- color/transparency ease rate between states
local DISPATCH_FLASH_SECONDS = 0.6 -- green ring snap right after rollover

-- Toast bookkeeping windows (display heuristics only — the server is truth).
local ROLLOVER_SETTLE_SECONDS = 0.3 -- let ActiveFloors/roster replicate first
local LEAVE_SUPPRESS_SECONDS = 2 -- a fresh Leave press is never "inactive"

local COLOR_PANEL = Color3.fromRGB(18, 20, 24)
local COLOR_TEXT = Color3.fromRGB(232, 230, 224)
local COLOR_LEAVE = Color3.fromRGB(180, 70, 60)
local COLOR_START = Color3.fromRGB(80, 220, 120)
local COLOR_START_READY = Color3.fromRGB(46, 120, 70)
local COLOR_TOAST_INFO = Color3.fromRGB(120, 220, 160)
local COLOR_TOAST_WARN = Color3.fromRGB(235, 190, 52)

-- Ring state palette (SOP §6.1 — idle cyan matches QueuePadBuilder's build tint).
local COLOR_RING_IDLE = Color3.fromRGB(90, 220, 255)
local COLOR_RING_QUEUED = Color3.fromRGB(255, 170, 60)
local COLOR_RING_FULL = Color3.fromRGB(80, 220, 120)
local COLOR_RING_STROBE = Color3.fromRGB(255, 255, 255)

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local QueuePadUI = {}

-- Last authoritative QueueState payload (contract §B; schema unchanged by R2,
-- endsAt = next T=0 under the metronome). The state NAME is not mirrored:
-- under the metronome the card gates on snapshot membership and the ring on
-- the RingState/DoorsClosing attributes — never on a state string.
local endsAt: number? = nil
local queueCount = 0
local rosterUserIds: { number } = {}
local readyUserIds: { number } = {}

-- Pad binding (streaming-safe; nil while the pad is streamed out / pre-build).
local padModel: Model? = nil
local padPart: BasePart? = nil
local zonePart: BasePart? = nil
local ringParts: { BasePart } = {}
local arrowTween: Tween? = nil

-- Ring animation state (eased toward the target each Heartbeat).
local ringColor = COLOR_RING_IDLE
local ringTransparency = LobbyConfig.QUEUE_RING_PULSE_TRANSPARENCY_MAX

-- Metronome bookkeeping (all display-side).
local lastCyclePhase: number? = nil -- (now - epoch) % CYCLE from the last tick
local dispatchFlashUntil = 0 -- os.clock() deadline for the green ring snap
local leaveSentAt = -math.huge -- os.clock() of the last local Leave press

-- GUI refs.
local uiScale: UIScale? = nil
local cardFrame: Frame? = nil
local cardLabel: TextLabel? = nil
local leaveButton: TextButton? = nil
local startButton: TextButton? = nil
local toastFrame: Frame? = nil
local toastLabel: TextLabel? = nil
local toastToken = 0

local invokeBusy = false
local rebindAccum = REBIND_SECONDS -- bind on the first tick

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function serverNow(): number
	return Workspace:GetServerTimeNow()
end

local function formatClock(seconds: number): string
	local s = math.max(0, math.ceil(seconds))
	return string.format("%d:%02d", s // 60, s % 60)
end

local function isLocalQueued(): boolean
	return table.find(rosterUserIds, LocalPlayer.UserId) ~= nil
end

local function isLocalReady(): boolean
	return table.find(readyUserIds, LocalPlayer.UserId) ~= nil
end

-- Attribute mirror reader: pad part first, then zone, then the model (the
-- server stamps all three — works even mid-stream-in).
local function readAttr(name: string): any
	local part = padPart
	local value = if part ~= nil then part:GetAttribute(name) else nil
	if value == nil and zonePart ~= nil then
		value = (zonePart :: BasePart):GetAttribute(name)
	end
	if value == nil and padModel ~= nil then
		value = (padModel :: Model):GetAttribute(name)
	end
	return value
end

local function readCountAttr(): number
	local value = readAttr(ATTR_QUEUE_COUNT)
	return if type(value) == "number" then value else queueCount
end

local function readActiveFloors(): number
	local value = readAttr(ATTR_ACTIVE_FLOORS)
	return if type(value) == "number" then value else 0
end

local function readDoorsClosing(): boolean
	return readAttr(ATTR_DOORS_CLOSING) == true
end

-- Remaining seconds to the next T=0, the WP5.3 way: locally ticked off the
-- once-set ShiftEpoch attribute — remaining = CYCLE - (now - epoch) % CYCLE.
-- Fallbacks (pre-epoch replication / legacy test places): the CountdownEndsAt
-- attribute, then the payload endsAt (both already "next T=0" under WP5.1).
local function remainingSeconds(): number?
	local epoch = readAttr(ATTR_SHIFT_EPOCH)
	if type(epoch) == "number" and epoch > 0 then
		return CYCLE_SECONDS - (serverNow() - epoch) % CYCLE_SECONDS
	end
	local deadline = readAttr(ATTR_COUNTDOWN_ENDS_AT)
	if type(deadline) ~= "number" or deadline <= 0 then
		deadline = endsAt
	end
	if type(deadline) == "number" then
		return math.max(0, deadline - serverNow())
	end
	return nil
end

-- DOORS CLOSING window (final FREEZE_SECONDS): attribute mirror first, local
-- epoch math as the race-proof fallback. Only meaningful with workers aboard.
local function inFreezeWindow(): boolean
	if readDoorsClosing() then
		return true
	end
	local remaining = remainingSeconds()
	return remaining ~= nil and remaining <= FREEZE_SECONDS and readCountAttr() > 0
end

--------------------------------------------------------------------------------
-- Remote sends (fire-and-forget with a client-side debounce; the server
-- enforces the real <= 5/10 s rate limit and snapshot membership — contract §B)
--------------------------------------------------------------------------------

local function sendLeave()
	if invokeBusy then
		return
	end
	invokeBusy = true
	leaveSentAt = os.clock() -- a voluntary step-out is never the AFK toast
	task.spawn(function()
		pcall(function()
			return Remotes.GetFunction("Queue.Leave"):InvokeServer()
		end)
		invokeBusy = false
	end)
end

local function sendSetReady(ready: boolean)
	if invokeBusy then
		return
	end
	invokeBusy = true
	task.spawn(function()
		pcall(function()
			return Remotes.GetFunction("Queue.SetReady"):InvokeServer(ready)
		end)
		invokeBusy = false
	end)
end

--------------------------------------------------------------------------------
-- Pad binding (streaming-safe: Atomic pad model is whole-or-absent)
--------------------------------------------------------------------------------

local function unbindPad()
	local tween = arrowTween
	if tween ~= nil then
		tween:Cancel()
		arrowTween = nil
	end
	padModel = nil
	padPart = nil
	zonePart = nil
	table.clear(ringParts)
end

local function bindPad(model: Model)
	padModel = model

	local pad = model:FindFirstChild(PAD_PART_NAME)
	padPart = if pad ~= nil and pad:IsA("BasePart") then pad else nil
	local zone = model:FindFirstChild(ZONE_PART_NAME)
	zonePart = if zone ~= nil and zone:IsA("BasePart") then zone else nil

	table.clear(ringParts)
	for _, child in model:GetChildren() do
		if child.Name == RING_PART_NAME and child:IsA("BasePart") then
			table.insert(ringParts, child)
		end
	end

	-- Billboard arrow bounce: ±QUEUE_ARROW_BOUNCE_STUDS Sine loop (SOP §6.1).
	-- Local-only motion on an anchored server part — never replicates.
	local arrow = model:FindFirstChild(ARROW_PART_NAME)
	if arrow ~= nil and arrow:IsA("BasePart") then
		local amplitude = Vector3.new(0, LobbyConfig.QUEUE_ARROW_BOUNCE_STUDS, 0)
		local base = arrow.Position
		arrow.Position = base + amplitude
		local tween = TweenService:Create(
			arrow,
			TweenInfo.new(
				LobbyConfig.QUEUE_ARROW_BOUNCE_SECONDS,
				Enum.EasingStyle.Sine,
				Enum.EasingDirection.InOut,
				-1, -- loop forever; cancelled on unbind
				true -- reverse: oscillates between +amp and -amp
			),
			{ Position = base - amplitude }
		)
		tween:Play()
		arrowTween = tween
	end
end

-- Re-resolves NightShiftHub.QueuePad whenever the bound model went stale
-- (streamed out / not yet built). Cheap FindFirstChild chain, 1 Hz throttled.
local function ensurePadBound()
	local current = padModel
	if current ~= nil and current:IsDescendantOf(Workspace) then
		return
	end
	unbindPad()

	local hub = Workspace:FindFirstChild(HUB_MODEL_NAME)
	local model = if hub ~= nil then hub:FindFirstChild(PAD_MODEL_NAME) else nil
	if model ~= nil and model:IsA("Model") then
		bindPad(model)
	end
end

-- Local body physically inside the clock-in zone volume (display-only input
-- to the AFK/deferral toast heuristics; membership is always the server's call).
local function isOnPad(): boolean
	local zone = zonePart
	if zone == nil then
		return false
	end
	local character = LocalPlayer.Character
	local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
	if root == nil or not root:IsA("BasePart") then
		return false
	end
	local offset = zone.CFrame:PointToObjectSpace(root.Position)
	local half = zone.Size / 2
	return math.abs(offset.X) <= half.X + ZONE_MARGIN_STUDS
		and math.abs(offset.Y) <= half.Y + ZONE_MARGIN_STUDS
		and math.abs(offset.Z) <= half.Z + ZONE_MARGIN_STUDS
end

--------------------------------------------------------------------------------
-- Ring tint & pulse (RingState attribute mirror; server owns state, client
-- owns every tween — addendum standing invariant)
--------------------------------------------------------------------------------

type RingMode = "idle" | "queued" | "full" | "doors" | "dispatch"

local function currentRingMode(): RingMode
	if os.clock() < dispatchFlashUntil then
		return "dispatch" -- brief green snap right after the T=0 launch
	end
	if inFreezeWindow() then
		return "doors" -- white rim flash, DOORS CLOSING (T-3..0)
	end

	-- Server RingState mirror (WP5.1 keeps the round-1 token family; map
	-- generously so an unknown token degrades to a sane tint, never an error).
	local ringState = readAttr(ATTR_RING_STATE)
	if type(ringState) == "string" then
		if ringState == "Final" or ringState == "DoorsClosing" then
			return "doors"
		elseif ringState == "Dispatch" or ringState == "Launching" then
			return "dispatch"
		elseif ringState == "Full" then
			return "full"
		elseif ringState == "Queued" then
			return "queued"
		end
		return "idle"
	end

	-- No attribute (pad streaming in): derive from the occupant count.
	return if readCountAttr() > 0 then "queued" else "idle"
end

local function updateRing(dt: number)
	if #ringParts == 0 then
		return
	end

	local mode = currentRingMode()
	local clock = os.clock()
	local targetColor: Color3
	local targetTransparency: number
	local snapTransparency = false

	if mode == "doors" then
		targetColor = COLOR_RING_STROBE
		local on = math.floor(clock * STROBE_HZ) % 2 == 0
		targetTransparency = if on then STROBE_TRANSPARENCY_ON else STROBE_TRANSPARENCY_OFF
		snapTransparency = true -- square wave, never eased
	elseif mode == "dispatch" then
		targetColor = COLOR_RING_FULL
		targetTransparency = STROBE_TRANSPARENCY_ON
		snapTransparency = true -- launch flash reads as one solid green pop
	elseif mode == "queued" then
		targetColor = COLOR_RING_QUEUED
		targetTransparency = RING_STEADY_TRANSPARENCY
	elseif mode == "full" then
		targetColor = COLOR_RING_FULL
		targetTransparency = RING_STEADY_TRANSPARENCY
	else -- idle: slow cyan pulse between the LobbyConfig tween bounds
		targetColor = COLOR_RING_IDLE
		local minT = LobbyConfig.QUEUE_RING_PULSE_TRANSPARENCY_MIN
		local maxT = LobbyConfig.QUEUE_RING_PULSE_TRANSPARENCY_MAX
		local wave = 0.5 + 0.5 * math.sin(clock * (2 * math.pi) / IDLE_PULSE_PERIOD_SECONDS)
		targetTransparency = minT + (maxT - minT) * wave
		snapTransparency = true -- the sine IS the ease
	end

	local alpha = math.clamp(dt * RING_LERP_PER_SECOND, 0, 1)
	ringColor = ringColor:Lerp(targetColor, alpha)
	ringTransparency = if snapTransparency
		then targetTransparency
		else ringTransparency + (targetTransparency - ringTransparency) * alpha

	for _, part in ringParts do
		part.Color = ringColor
		part.Transparency = ringTransparency
	end
end

--------------------------------------------------------------------------------
-- Screen GUI (on-pad card + toast slot)
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

local function makeButton(parent: Instance, name: string, text: string, color: Color3, xOffset: number): TextButton
	local button = Instance.new("TextButton")
	button.Name = name
	button.AnchorPoint = Vector2.new(0.5, 1)
	button.Position = UDim2.new(0.5, xOffset, 1, -8)
	button.Size = UDim2.fromOffset(BUTTON_WIDTH_PX, BUTTON_HEIGHT_PX)
	button.BackgroundColor3 = color
	button.BackgroundTransparency = 0.12
	button.BorderSizePixel = 0
	button.Font = Enum.Font.GothamBold
	button.TextSize = 18
	button.TextColor3 = COLOR_TEXT
	button.Text = text
	button.Parent = parent
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = button
	return button
end

local function buildScreenGui(): ScreenGui
	local gui = Instance.new("ScreenGui")
	gui.Name = "QueuePadUI"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = false
	gui.ScreenInsets = Enum.ScreenInsets.DeviceSafeInsets
	gui.DisplayOrder = 14 -- above CountdownUI (12), below the unboxing theater (20)

	local root = Instance.new("Frame")
	root.Name = "Root"
	root.Size = UDim2.fromScale(1, 1)
	root.BackgroundTransparency = 1
	root.Parent = gui

	local scale = Instance.new("UIScale")
	scale.Parent = root
	uiScale = scale

	-- On-pad card: countdown line over the two action buttons. Bottom-center
	-- keeps both thumbs' corner zones clear (SOP §3.2 / §8 screen layout).
	local card = Instance.new("Frame")
	card.Name = "QueueCard"
	card.AnchorPoint = Vector2.new(0.5, 1)
	card.Position = UDim2.new(0.5, 0, 1, -CARD_BOTTOM_PX)
	card.Size = UDim2.fromOffset(CARD_WIDTH_PX, CARD_HEIGHT_PX)
	card.BackgroundColor3 = COLOR_PANEL
	card.BackgroundTransparency = 0.12
	card.BorderSizePixel = 0
	card.Visible = false
	card.Parent = root
	cardFrame = card
	local cardCorner = Instance.new("UICorner")
	cardCorner.CornerRadius = UDim.new(0, 12)
	cardCorner.Parent = card
	local cardStroke = Instance.new("UIStroke")
	cardStroke.Thickness = 1.5
	cardStroke.Color = COLOR_RING_IDLE
	cardStroke.Parent = card

	local status = Instance.new("TextLabel")
	status.Name = "Status"
	status.BackgroundTransparency = 1
	status.Position = UDim2.fromOffset(0, 8)
	status.Size = UDim2.new(1, 0, 0, 30)
	status.Font = Enum.Font.GothamBold
	status.TextSize = 19
	status.TextColor3 = COLOR_TEXT
	status.Text = ""
	status.Parent = card
	cardLabel = status

	leaveButton = makeButton(card, "LeaveButton", "Leave", COLOR_LEAVE, -(BUTTON_WIDTH_PX / 2 + 8))
	startButton = makeButton(card, "StartNowButton", "Start now", COLOR_START, BUTTON_WIDTH_PX / 2 + 8)

	-- One-shot toast slot (dispatch flash / deferral / AFK), above the card —
	-- same token idiom as CountdownUI's rotation toast.
	local toast = Instance.new("Frame")
	toast.Name = "PadToast"
	toast.AnchorPoint = Vector2.new(0.5, 1)
	toast.Position = UDim2.new(0.5, 0, 1, -TOAST_BOTTOM_PX)
	toast.Size = UDim2.fromOffset(TOAST_WIDTH_PX, TOAST_HEIGHT_PX)
	toast.BackgroundColor3 = COLOR_PANEL
	toast.BackgroundTransparency = 0.15
	toast.BorderSizePixel = 0
	toast.Visible = false
	toast.Parent = root
	toastFrame = toast
	local toastCorner = Instance.new("UICorner")
	toastCorner.CornerRadius = UDim.new(0, 8)
	toastCorner.Parent = toast

	local toastText = Instance.new("TextLabel")
	toastText.Name = "Text"
	toastText.BackgroundTransparency = 1
	toastText.Size = UDim2.fromScale(1, 1)
	toastText.Font = Enum.Font.GothamBold
	toastText.TextSize = 15
	toastText.TextColor3 = COLOR_TOAST_INFO
	toastText.TextTruncate = Enum.TextTruncate.AtEnd
	toastText.Text = ""
	toastText.Parent = toast
	toastLabel = toastText

	return gui
end

local function showToast(text: string, color: Color3)
	local frame = toastFrame
	local label = toastLabel
	if frame == nil or label == nil then
		return
	end
	toastToken += 1
	local token = toastToken
	label.Text = text
	label.TextColor3 = color
	frame.Visible = true
	task.delay(TOAST_SECONDS, function()
		if toastToken == token and frame ~= nil then
			frame.Visible = false
		end
	end)
end

--------------------------------------------------------------------------------
-- Card render
--------------------------------------------------------------------------------

local function renderCard()
	local card = cardFrame
	local label = cardLabel
	if card == nil or label == nil then
		return
	end

	-- Visible whenever the LOCAL player is in the pad snapshot — the metronome
	-- pad never sleeps, so membership (not a state name) gates the card.
	local queued = isLocalQueued()
	card.Visible = queued
	if not queued then
		return
	end

	local count = readCountAttr()
	if inFreezeWindow() then
		label.Text = `DOORS CLOSING — CLOCKED IN: {count}`
	else
		local remaining = remainingSeconds()
		if remaining ~= nil then
			label.Text = `NEXT SHIFT {formatClock(remaining)} — CLOCKED IN: {count}`
		else
			label.Text = `CLOCKED IN: {count}`
		end
	end

	-- Both buttons stay live through T=0: stepping off ALWAYS works (only
	-- late ENTRY locks at T-3 — Change 6.1.3), and the vote is the server's
	-- call to honor. No T-1 lock UI under the metronome.
	local start = startButton
	if start ~= nil then
		local ready = isLocalReady()
		start.Text = if ready then "Ready ✓" else "Start now"
		start.BackgroundColor3 = if ready then COLOR_START_READY else COLOR_START
	end
end

--------------------------------------------------------------------------------
-- QueueState payload (contract §B: transitions + 1 Hz while counting; same
-- schema as round 1 — the AFK drop is read from the roster diff)
--------------------------------------------------------------------------------

local function onQueueState(payload: any)
	if type(payload) ~= "table" or type(payload.state) ~= "string" then
		return
	end

	local wasQueued = isLocalQueued()

	endsAt = if type(payload.endsAt) == "number" then payload.endsAt else nil
	queueCount = if type(payload.count) == "number" then payload.count else 0
	rosterUserIds = if type(payload.rosterUserIds) == "table" then payload.rosterUserIds else {}
	readyUserIds = if type(payload.readyUserIds) == "table" then payload.readyUserIds else {}

	-- AFK "Clocked out — inactive" (Change 6.1.6). Primary: the additive
	-- afkUserIds payload field when WP5.1 ships it. Fallback heuristic: the
	-- server dropped us MID-CYCLE (dispatch removals only happen at T=0)
	-- while we are still standing on the pad and did not press Leave.
	if wasQueued and not isLocalQueued() then
		local afkIds = payload.afkUserIds
		local flaggedAfk = type(afkIds) == "table" and table.find(afkIds, LocalPlayer.UserId) ~= nil
		if not flaggedAfk then
			local remaining = remainingSeconds()
			flaggedAfk = remaining ~= nil
				and remaining > FREEZE_SECONDS + 1
				and remaining < CYCLE_SECONDS - 1
				and os.clock() - leaveSentAt > LEAVE_SUPPRESS_SECONDS
				and isOnPad()
		end
		if flaggedAfk then
			showToast("Clocked out — inactive", COLOR_TOAST_WARN)
		end
	end

	renderCard()
end

--------------------------------------------------------------------------------
-- Epoch rollover (T=0) — dispatch flash + deferral toast
--------------------------------------------------------------------------------

-- Detected locally off the ShiftEpoch phase wrap; the settle delay lets the
-- ActiveFloors attribute and the post-dispatch roster replicate first.
local function onRollover(countBefore: number, queuedBefore: boolean)
	if countBefore <= 0 then
		return -- empty pad at T=0: silent rollover, no flash (Change 6.1.2)
	end
	dispatchFlashUntil = os.clock() + DISPATCH_FLASH_SECONDS

	task.delay(ROLLOVER_SETTLE_SECONDS, function()
		local floors = readActiveFloors()
		-- Deferred bin: we were in the snapshot, every floor slot is busy,
		-- and we are still aboard the pad after the dispatch tick.
		if queuedBefore and floors >= SLOT_COUNT and (isLocalQueued() or isOnPad()) then
			showToast("ALL FLOORS RUNNING", COLOR_TOAST_WARN)
			return
		end
		if floors > 0 then
			local noun = if floors == 1 then "FLOOR" else "FLOORS"
			showToast(`SHIFT STARTED — {floors} {noun} RUNNING`, COLOR_TOAST_INFO)
		end
	end)
end

local function checkRollover()
	local epoch = readAttr(ATTR_SHIFT_EPOCH)
	if type(epoch) ~= "number" or epoch <= 0 then
		lastCyclePhase = nil
		return
	end
	local phase = (serverNow() - epoch) % CYCLE_SECONDS
	local previous = lastCyclePhase
	-- Snapshot the pre-rollover view BEFORE updating bookkeeping.
	if previous ~= nil and phase < previous then
		onRollover(readCountAttr(), isLocalQueued())
	end
	lastCyclePhase = phase
end

--------------------------------------------------------------------------------
-- Heartbeat tick — the ONE animation/maintenance loop
--------------------------------------------------------------------------------

local function onHeartbeat(dt: number)
	rebindAccum += dt
	if rebindAccum >= REBIND_SECONDS then
		rebindAccum = 0
		ensurePadBound()
	end

	checkRollover()
	updateRing(dt)
	renderCard()
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

function QueuePadUI.IsQueued(): boolean
	return isLocalQueued()
end

--------------------------------------------------------------------------------
-- Loader lifecycle
--------------------------------------------------------------------------------

function QueuePadUI:Start()
	-- Everything lives in Start (spawned): Remotes.Get yields on the client and
	-- Init must not (§A loader contract).
	local playerGui = LocalPlayer:WaitForChild("PlayerGui")

	local gui = buildScreenGui()
	gui.Parent = playerGui

	updateScale()
	local camera = Workspace.CurrentCamera
	if camera ~= nil then
		camera:GetPropertyChangedSignal("ViewportSize"):Connect(updateScale)
	end

	local leave = leaveButton
	if leave ~= nil then
		local leaveRef: TextButton = leave
		leaveRef.Activated:Connect(function()
			if leaveRef.Active then
				sendLeave()
			end
		end)
	end
	local start = startButton
	if start ~= nil then
		local startRef: TextButton = start
		startRef.Activated:Connect(function()
			if startRef.Active then
				sendSetReady(not isLocalReady())
			end
		end)
	end

	Remotes.GetEvent("QueueState").OnClientEvent:Connect(onQueueState)

	RunService.Heartbeat:Connect(onHeartbeat)
end

return QueuePadUI
