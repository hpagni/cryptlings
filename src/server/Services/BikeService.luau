--!strict
-- CRYPTLINGS: NIGHT SHIFT — BikeService (R3-5, Lobby SOP Addendum 2; R3 plan
-- decisions §6/§7). Server owner of the lobby bicycle: the "Bike.SetActive"
-- RemoteFunction, the server-set "BikeActive" player attribute, and the welded
-- cosmetic greybox bike ("LobbyBike", parented under the character so engine
-- cleanup is automatic).
--
-- Authority model (contract in Shared.Net.Remotes):
--   * "BikeActive" is a DISPLAY/SPEED MIRROR: set ONLY here and consumed by
--     exactly the two existing speed owners — server CaseService.ApplyCarrySpeed
--     and the client InputController. This service NEVER writes Humanoid speed
--     itself (Shared.Logic.PetPerks line 8: never a third writer), and NO
--     server logic ever reads the attribute as authorization or decision input.
--   * The cosmetic is pure greybox: Massless, no-collide/no-query/no-touch
--     parts welded into one assembly under the HumanoidRootPart, ONE Neon
--     strip for the night-street glow — ZERO Light instances (the 50-light
--     budget is full).
--
-- Weld topology (Addendum 3 R4-3 — the weld NAMES below are a FROZEN CLIENT
-- CONTRACT, consumed by the BikeRigPose controller; future rounds must not
-- rename or reparent them):
--   * Frame -> root: legacy Weld "FrameWeld" (Part0 = root, Part1 = Frame,
--     C0 captured from the rest pose at build, parented in Frame). Legacy
--     Weld because clients lean the frame by mutating C0 locally — a
--     WeldConstraint cannot animate.
--   * FrontWheel/RearWheel -> Frame: legacy Welds named "SpinWeld" (Part0 =
--     Frame, parented in each wheel) — clients spin C0 locally.
--   * Handlebar/GlowStrip -> Frame: WeldConstraint (these never animate).
--   Rest-pose geometry is identical to a rigid build; the server NEVER
--   mutates a C0 after build — every spin/lean is client-local cosmetics
--   (BikeRigPose), and the assembly raise (-1.4) puts the saddle (Frame top)
--   under LowerTorso for the client ride pose.
--
-- Mount gating (fail-closed; a missing sibling REFUSES the mount): arg must be
-- EXACTLY a boolean, per-player rate limit <= 5 calls / 10 s sliding window,
-- never on a shift (ShiftService.GetSessionOf(player) == nil), character
-- alive, HumanoidRootPart within LobbyConfig.BIKE.LOBBY_RADIUS_STUDS
-- (horizontal) of the hub spawn. The handler never yields.
--
-- Auto-dismount ("never on factory floors" is double-walled, R3-5):
--   * Structural wall: ShiftSession._start pcalls ForceDismount immediately
--     BEFORE each dispatch PivotTo (and therefore before noteServerTeleport) —
--     a bike can never exist on a factory floor.
--   * Event triggers: humanoid.Died, humanoid.Seated (any seat),
--     Player.CharacterRemoving (no respawn persistence), Players.PlayerRemoving.
--   * Enforcement loop every LobbyConfig.BIKE.ENFORCE_SECONDS over MOUNTED
--     players only, degrade closed (sibling missing => dismount): on a shift,
--     carrying cases, on the metronome queue pad (QueuePadService.IsOnPad), on
--     a trade pad (HubService.GetTradePads XZ bounds + the 6-stud Y-tolerance
--     idiom from TradeService.isOnTradePad), outside the lobby radius, or
--     occupying any seat (WP2.3 audit: SeatPart sweep covers the
--     seated-BEFORE-mount case the Seated event transition never fires for).
--
-- Public API (siblings pcall-fence their calls):
--   BikeService.ForceDismount(player)         -- idempotent
--   BikeService.IsActive(player) -> boolean

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local LobbyConfig = require(Shared:WaitForChild("Config"):WaitForChild("LobbyConfig"))
local Remotes = require(Shared:WaitForChild("Net"):WaitForChild("Remotes"))

local BIKE = LobbyConfig.BIKE

--------------------------------------------------------------------------------
-- Local tuning (idiom mirrors, not lobby tunables of record)
--------------------------------------------------------------------------------

-- Rate limit per the Remotes.luau contract (Queue.SetReady idiom): <= 5 calls
-- per 10 s sliding window, keyed by Player, cleared ONLY on PlayerRemoving.
local RATE_LIMIT_CALLS = 5
local RATE_LIMIT_WINDOW_SECONDS = 10

-- TradeService.isOnTradePad idiom: XZ half-extents + slack, 6-stud Y band.
local TRADE_PAD_Y_TOLERANCE = 6
local TRADE_PAD_XZ_SLACK = 0.5

-- Greybox cosmetic colors (dark SmoothPlastic body; the glow strip color of
-- record is LobbyConfig.BIKE.NEON_STRIP_COLOR).
local BIKE_BODY_COLOR = Color3.fromRGB(38, 40, 50)
local BIKE_WHEEL_COLOR = Color3.fromRGB(24, 25, 32)

--------------------------------------------------------------------------------
-- Lazy sibling resolution (house pattern — see CaseService)
--------------------------------------------------------------------------------

local siblingCache: { [string]: any } = {}

local function getSibling(name: string): any
	local cached = siblingCache[name]
	if cached ~= nil then
		if cached == false then
			return nil
		end
		return cached
	end
	local container = script.Parent
	local module = container and container:FindFirstChild(name)
	local result: any = nil
	if module ~= nil and module:IsA("ModuleScript") then
		local ok, required = pcall(require, module)
		if ok and type(required) == "table" then
			result = required
		end
	end
	siblingCache[name] = if result ~= nil then result else false
	return result
end

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

type MountRecord = {
	model: Model,
	connections: { RBXScriptConnection },
}

local BikeService = {}

local mounted: { [Player]: MountRecord } = {}
local rateTimes: { [Player]: { number } } = {}

--------------------------------------------------------------------------------
-- Rate limiting (sliding window; TradeService.consumeInviteToken idiom)
--------------------------------------------------------------------------------

local function consumeRateToken(player: Player): boolean
	local clock = os.clock()
	local times = rateTimes[player]
	if times == nil then
		times = {}
		rateTimes[player] = times
	end
	for index = #times, 1, -1 do
		if clock - times[index] > RATE_LIMIT_WINDOW_SECONDS then
			table.remove(times, index)
		end
	end
	if #times >= RATE_LIMIT_CALLS then
		return false
	end
	table.insert(times, clock)
	return true
end

--------------------------------------------------------------------------------
-- Dismount conditions (every sibling call pcall-fenced; degrade CLOSED — a
-- missing/failing sibling reads as "must dismount")
--------------------------------------------------------------------------------

local function isOnShift(player: Player): boolean
	local shift = getSibling("ShiftService")
	if shift == nil or type(shift.GetSessionOf) ~= "function" then
		return true
	end
	local ok, session = pcall(shift.GetSessionOf, player)
	return not ok or session ~= nil
end

local function isCarryingCases(player: Player): boolean
	local caseService = getSibling("CaseService")
	if caseService == nil or type(caseService.GetCarriedCount) ~= "function" then
		return true
	end
	local ok, count = pcall(caseService.GetCarriedCount, player)
	return not ok or (tonumber(count) or 1) > 0
end

local function isOnQueuePad(player: Player): boolean
	local queuePadService = getSibling("QueuePadService")
	if queuePadService == nil or type(queuePadService.IsOnPad) ~= "function" then
		return true
	end
	local ok, onPad = pcall(queuePadService.IsOnPad, player)
	return not ok or onPad == true
end

local function isOnTradePad(root: BasePart): boolean
	local hub = getSibling("HubService")
	if hub == nil or type(hub.GetTradePads) ~= "function" then
		return true
	end
	local ok, pads = pcall(hub.GetTradePads)
	if not ok or type(pads) ~= "table" then
		return true
	end
	for _, pad in pads :: { BasePart } do
		local offset = root.Position - pad.Position
		if
			math.abs(offset.X) <= pad.Size.X / 2 + TRADE_PAD_XZ_SLACK
			and math.abs(offset.Z) <= pad.Size.Z / 2 + TRADE_PAD_XZ_SLACK
			and offset.Y >= -2
			and offset.Y <= TRADE_PAD_Y_TOLERANCE
		then
			return true
		end
	end
	return false
end

-- Horizontal (XZ) distance from the hub spawn vs the lobby radius of record.
local function isOutOfLobbyBounds(root: BasePart): boolean
	local hub = getSibling("HubService")
	if hub == nil or type(hub.GetSpawnPosition) ~= "function" then
		return true
	end
	local ok, spawnPosition = pcall(hub.GetSpawnPosition)
	if not ok or typeof(spawnPosition) ~= "Vector3" then
		return true
	end
	local offset = root.Position - spawnPosition
	return Vector3.new(offset.X, 0, offset.Z).Magnitude > BIKE.LOBBY_RADIUS_STUDS
end

local function shouldDismount(player: Player): boolean
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if character == nil or humanoid == nil or humanoid.Health <= 0 or root == nil or not root:IsA("BasePart") then
		return true
	end
	-- R3 security audit (WP2.3 hardening): a player ALREADY seated when they
	-- mount never fires the Seated event trigger (it only fires on
	-- transitions) — sweep SeatPart so any seat occupancy dismounts within one
	-- enforcement tick, same loop-enforced posture as the pad checks below.
	if humanoid.SeatPart ~= nil then
		return true
	end
	return isOnShift(player)
		or isCarryingCases(player)
		or isOnQueuePad(player)
		or isOnTradePad(root)
		or isOutOfLobbyBounds(root)
end

--------------------------------------------------------------------------------
-- Cosmetic build (5 greybox parts ~MODEL_WIDTH x MODEL_HEIGHT x MODEL_LENGTH:
-- frame slab, handlebar, 2 wheel cylinders, ONE Neon strip — zero Lights).
-- Weld topology per the header contract (R4-3): legacy "FrameWeld"
-- (root -> Frame) + two legacy "SpinWeld"s (Frame -> wheel) so clients can
-- animate C0 locally; Handlebar/GlowStrip ride on rigid WeldConstraints.
--------------------------------------------------------------------------------

local function makeBikePart(model: Model, name: string, size: Vector3, cframe: CFrame): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = cframe
	part.Anchored = false
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
	part.Color = BIKE_BODY_COLOR
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = model
	return part
end

-- Rigid attach for the parts that never animate (Handlebar, GlowStrip).
local function weldRigid(part0: BasePart, part1: BasePart)
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = part0
	weld.Part1 = part1
	weld.Parent = part1
end

local function buildBike(character: Model, root: BasePart): Model
	local model = Instance.new("Model")
	model.Name = "LobbyBike"

	local length = BIKE.MODEL_LENGTH
	local height = BIKE.MODEL_HEIGHT
	local width = BIKE.MODEL_WIDTH
	-- Under the character, long axis along the facing direction (root -Z).
	-- R4-3: raised from -2.2 so the saddle (Frame top) sits under LowerTorso;
	-- pairs with the owning client's HipHeight +0.6 (BikeRigPose) so the bent
	-- legs clear the ground and the wheels touch. Tuned visually in smoke.
	local base = root.CFrame * CFrame.new(0, -1.4, 0)

	local frame = makeBikePart(model, "Frame", Vector3.new(0.4, height, length * 0.7), base * CFrame.new(0, 0.2, 0))
	-- Legacy Weld of record: rest-pose C0 captured at build; clients mutate C0
	-- LOCALLY only (frame lean) — the server never touches it again.
	local frameWeld = Instance.new("Weld")
	frameWeld.Name = "FrameWeld"
	frameWeld.Part0 = root
	frameWeld.Part1 = frame
	frameWeld.C0 = root.CFrame:Inverse() * frame.CFrame
	frameWeld.Parent = frame

	local handlebar = makeBikePart(
		model,
		"Handlebar",
		Vector3.new(width, 0.25, 0.25),
		base * CFrame.new(0, height * 0.5 + 0.3, -length * 0.32)
	)
	weldRigid(frame, handlebar)

	-- Cylinder axis = X, so the wheel disc rolls along the travel (Z) axis;
	-- clients spin each wheel about that axis via SpinWeld.C0 (local only).
	local wheelSize = Vector3.new(0.3, height + 0.4, height + 0.4)
	local front = makeBikePart(model, "FrontWheel", wheelSize, base * CFrame.new(0, -height * 0.4, -(length / 2 - 0.7)))
	front.Shape = Enum.PartType.Cylinder
	front.Color = BIKE_WHEEL_COLOR
	local frontSpin = Instance.new("Weld")
	frontSpin.Name = "SpinWeld"
	frontSpin.Part0 = frame
	frontSpin.Part1 = front
	frontSpin.C0 = frame.CFrame:Inverse() * front.CFrame
	frontSpin.Parent = front

	local rear = makeBikePart(model, "RearWheel", wheelSize, base * CFrame.new(0, -height * 0.4, length / 2 - 0.7))
	rear.Shape = Enum.PartType.Cylinder
	rear.Color = BIKE_WHEEL_COLOR
	local rearSpin = Instance.new("Weld")
	rearSpin.Name = "SpinWeld"
	rearSpin.Part0 = frame
	rearSpin.Part1 = rear
	rearSpin.C0 = frame.CFrame:Inverse() * rear.CFrame
	rearSpin.Parent = rear

	local strip = makeBikePart(
		model,
		"GlowStrip",
		Vector3.new(0.2, 0.12, length * 0.8),
		base * CFrame.new(0, height * 0.5 + 0.12, 0)
	)
	strip.Material = Enum.Material.Neon
	strip.Color = Color3.fromRGB(BIKE.NEON_STRIP_COLOR.R, BIKE.NEON_STRIP_COLOR.G, BIKE.NEON_STRIP_COLOR.B)
	weldRigid(frame, strip)

	model.PrimaryPart = frame
	model.Parent = character
	return model
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

function BikeService.IsActive(player: Player): boolean
	return mounted[player] ~= nil
end

-- Idempotent: clears the attribute mirror, destroys the cosmetic, drops the
-- triggers, then re-settles speed through its server owner (the exact
-- PetService applyPerks idiom — this service never writes speed itself).
function BikeService.ForceDismount(player: Player)
	local record = mounted[player]
	mounted[player] = nil
	if record ~= nil then
		for _, connection in record.connections do
			pcall(function()
				connection:Disconnect()
			end)
		end
		record.model:Destroy()
	end
	-- Defensive: catch a stray cosmetic (e.g. a record lost to a Character
	-- swap) so no orphaned "LobbyBike" ever survives a dismount.
	local character = player.Character
	local stray = character and character:FindFirstChild("LobbyBike")
	if stray ~= nil then
		stray:Destroy()
	end

	player:SetAttribute("BikeActive", nil)

	local caseService = getSibling("CaseService")
	if caseService ~= nil and type(caseService.ApplyCarrySpeed) == "function" then
		pcall(caseService.ApplyCarrySpeed, player)
	end
end

--------------------------------------------------------------------------------
-- Mount / remote handler
--------------------------------------------------------------------------------

local function mount(player: Player): { [string]: any }
	if mounted[player] ~= nil then
		return { ok = true, active = true } -- already riding; nothing to rebuild
	end

	-- Never on a shift — fail closed when the session facade is unavailable.
	local shift = getSibling("ShiftService")
	if shift == nil or type(shift.GetSessionOf) ~= "function" then
		return { ok = false, active = false, err = "ON_SHIFT" }
	end
	local okSession, session = pcall(shift.GetSessionOf, player)
	if not okSession or session ~= nil then
		return { ok = false, active = false, err = "ON_SHIFT" }
	end

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if character == nil or humanoid == nil or humanoid.Health <= 0 or root == nil or not root:IsA("BasePart") then
		return { ok = false, active = false, err = "DEAD" }
	end

	-- Lobby radius check — fail closed when HubService is unavailable.
	if isOutOfLobbyBounds(root) then
		return { ok = false, active = false, err = "OUT_OF_BOUNDS" }
	end

	-- R3 security audit (WP2.3 hardening) — fail-closed grant atomicity: build
	-- the cosmetic FIRST and only then set the attribute mirror. The reverse
	-- order could (on any build error) leave the speed-grant attribute set with
	-- no mounted record — a state the enforcement loop can never sweep, because
	-- it iterates records only. ForceDismount in the failure branch is the
	-- idempotent cleanup: attribute clear + stray-cosmetic sweep.
	local okBuild, model = pcall(buildBike, character, root)
	if not okBuild then
		BikeService.ForceDismount(player)
		return { ok = false, active = false, err = "DEAD" }
	end
	player:SetAttribute("BikeActive", true)

	local connections: { RBXScriptConnection } = {
		humanoid.Died:Connect(function()
			BikeService.ForceDismount(player)
		end),
		humanoid.Seated:Connect(function(isSeated: boolean)
			if isSeated then
				BikeService.ForceDismount(player) -- any seat dismounts (R3-5)
			end
		end),
		player.CharacterRemoving:Connect(function()
			BikeService.ForceDismount(player) -- no persistence across respawn
		end),
	}
	mounted[player] = { model = model, connections = connections }

	-- Re-settle through the server speed owner so both owners read the fresh
	-- attribute immediately (PetService applyPerks line 282 idiom).
	local caseService = getSibling("CaseService")
	if caseService ~= nil and type(caseService.ApplyCarrySpeed) == "function" then
		pcall(caseService.ApplyCarrySpeed, player)
	end
	return { ok = true, active = true }
end

-- Bike.SetActive (contract in Remotes.luau): boolean-only fail-closed, rate
-- limited, never yields; any non-boolean arg returns with ZERO side effects.
local function onSetActive(player: Player, active: any): { [string]: any }
	if active ~= true and active ~= false then
		return { ok = false, active = BikeService.IsActive(player), err = "BAD_ARG" }
	end
	if not consumeRateToken(player) then
		return { ok = false, active = BikeService.IsActive(player), err = "RATE_LIMIT" }
	end
	if active == false then
		BikeService.ForceDismount(player) -- idempotent; dismount is always honored
		return { ok = true, active = false }
	end
	return mount(player)
end

--------------------------------------------------------------------------------
-- Loader lifecycle
--------------------------------------------------------------------------------

function BikeService:Init()
	local ok, err = pcall(function()
		Remotes.GetFunction("Bike.SetActive").OnServerInvoke = function(player: Player, active: any)
			return onSetActive(player, active)
		end
	end)
	if not ok then
		warn(`[BikeService] remote bind failed: {err}`)
	end

	Players.PlayerRemoving:Connect(function(player: Player)
		BikeService.ForceDismount(player)
		rateTimes[player] = nil -- the ONLY place the rate limiter is cleared
	end)
end

function BikeService:Start()
	-- Enforcement loop (R3-5): every ENFORCE_SECONDS, sweep MOUNTED players
	-- only and force-dismount anyone in a state the bike must never survive.
	while true do
		task.wait(BIKE.ENFORCE_SECONDS)
		local riders: { Player } = {}
		for player in mounted do
			table.insert(riders, player)
		end
		for _, player in riders do
			if mounted[player] ~= nil and shouldDismount(player) then
				BikeService.ForceDismount(player)
			end
		end
	end
end

return BikeService
