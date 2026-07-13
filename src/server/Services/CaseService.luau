--!strict
-- CRYPTLINGS: NIGHT SHIFT — CaseService (Stage 1 "Run loop"; SOP §3.1 ①, §1.2).
-- Spawns greybox case Models at tagged anchors on shift start, runs the
-- carry/weld stack, the greed-dial noise model (contract §G: squirm NoiseEvents
-- + movement contribution + the owner-only NoiseMeter), and the
-- pickup/drop/steal-from-downed-teammate flows.
--
-- Public API (contract I + Stage 1 siblings):
--   CaseService.GetMaxCarry(player) -> number   -- BASE_CARRY_SLOTS + PASS_CARRY bonus (pcall-safe)
--   CaseService.SpawnForShift(floorRoot, rng)   -- ShiftService/ShiftSession, on shift
--                                               -- start (stamps records with floorRoot)
--   CaseService.SpawnCaseAt(tier, position, guaranteedRarity?) -> uid? -- Stage 6: ConsumableService's vault case
--   CaseService.ServerPickup(player, uid) -> boolean -- intro floor: server-authoritative carry (no session gate)
--   CaseService.ClearShift(floorRoot: Instance?) -- ShiftService/ShiftSession, on shift
--                                               -- complete. nil = clear everything
--                                               -- (legacy); non-nil = only that floor's
--                                               -- records (R2 WP4.1 session scoping)
--   CaseService.ApplyCarrySpeed(player)         -- re-applies carry-weighted WalkSpeed
--   CaseService.GetCarriedCount(player) -> number
--   CaseService.GetCarried(player) -> { { uid: string, tier: number } }
--   CaseService.TakeAllCarried(player) -> { { uid: string, tier: number } }
--                                               -- ExtractionService banking (fires CaseEvent "Banked")
--   CaseService.ScatterCarried(player, position) -> number -- death: cases become world pickups
--   CaseService.LoseCarried(player) -> number   -- shift-end loss (fires CaseEvent "Lost")
--
-- Optional siblings consumed via pcall (degrade gracefully when absent):
--   NoiseService.Emit({ pos, loudness, source }) / NoiseService.GetPlayerCaseMult(player)
--   MonetizationService.OwnsPass(player, "PASS_CARRY")
--   ShiftService (sibling, owned by this stage): IsActive / IsDowned, plus the
--   R2 additive session facade (feature-detected, legacy fallback when absent):
--   GetSessionOf / GetFloorRootFor / GetShiftIdFor

local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConstants = require(Shared:WaitForChild("Config"):WaitForChild("GameConstants"))
local Remotes = require(Shared:WaitForChild("Net"):WaitForChild("Remotes"))
local Util = require(Shared:WaitForChild("Util"))

--------------------------------------------------------------------------------
-- Stage-1 local tuning (not in GameConstants v1 — flagged to the integrator)
--------------------------------------------------------------------------------

local PICKUP_RANGE_STUDS = GameConstants.PICKUP_RANGE_STUDS -- shared with the client's contextual targeting
local CASE_ANCHOR_FILL = 0.6 -- spec: fill 60% of tagged anchors
local NOISE_METER_INTERVAL_SECONDS = 0.3
local MOVEMENT_EMIT_INTERVAL_SECONDS = 1.0 -- world-noise cadence while moving with cases
local WOBBLE_INTERVAL_SECONDS = 0.8 -- world-case squirm jitter
local WOBBLE_MAX_RADIANS = math.rad(5)
local MOVING_SPEED_THRESHOLD = 0.5
local CARRY_BACK_OFFSET_STUDS = 1 -- behind the back, plus half the case depth
local CARRY_STACK_STEP_STUDS = 1.75
local CASE_BODY_SIZE = Vector3.new(2.4, 1.6, 1.6)
local CASE_STRIPE_SIZE = Vector3.new(2.5, 0.35, 1.7)
local CASE_BODY_COLOR = Color3.fromRGB(148, 126, 100) -- greybox cardboard
-- Six case tiers, stripes following the rarity ladder colors (§E): the deeper
-- the floor, the better (and rarer) the crate. T6 = the rainbow box.
local TIER_STRIPE_COLORS: { [number]: Color3 } = {
	[1] = Color3.fromRGB(178, 178, 178), -- Tier 1: common grey
	[2] = Color3.fromRGB(85, 170, 85), -- Tier 2: green (baseline tier)
	[3] = Color3.fromRGB(60, 120, 216), -- Tier 3: blue
	[4] = Color3.fromRGB(140, 80, 200), -- Tier 4: purple (deep floor)
	[5] = Color3.fromRGB(230, 60, 50), -- Tier 5: red (statistically not every game)
	[6] = Color3.fromRGB(255, 80, 220), -- Tier 6: rainbow box (hue-cycles live)
}

-- Sprint detection from actual velocity (sprinting itself is a client control).
local SPRINT_DETECT_SPEED = (GameConstants.WALKSPEED_BASE + GameConstants.SPRINT_SPEED) / 2

-- CollectionService tag shared with FloorGenService / ShiftService's fallback floor.
local TAG_CASE_ANCHOR = "CaseAnchor"

-- Client contract (InputController targets cases by this tag + attribute, and
-- treats a case as carried when it is parented under a character).
local TAG_CASE = "Case"
local ATTR_CASE_UID = "caseUid"

--------------------------------------------------------------------------------
-- Lazy sibling resolution
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

local function track(player: Player, event: string, props: { [string]: any }?)
	local analytics = getSibling("AnalyticsService")
	if analytics ~= nil and type(analytics.Track) == "function" then
		pcall(analytics.Track, player, event, props)
	end
end

local function funnelStep(player: Player, step: number, stepName: string)
	local analytics = getSibling("AnalyticsService")
	if analytics ~= nil and type(analytics.FunnelStep) == "function" then
		pcall(analytics.FunnelStep, player, step, stepName)
	end
end

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

type CaseRecord = {
	uid: string,
	tier: number,
	model: Model,
	body: BasePart,
	state: "world" | "carried",
	holder: Player?,
	baseCFrame: CFrame?, -- world cases: wobble origin
	carryWeld: WeldConstraint?,
	squirmThread: thread?,
	mega: boolean?, -- mega crate: guarantees a Mythical, grab-locks the shift
	floorRoot: Instance?, -- R2 WP4.1: owning session floor (nil = unattributed stray)
	guaranteedRarity: string?, -- intro floor: forces the rarity this case opens into
}

local CaseService = {}

local cases: { [string]: CaseRecord } = {}
local carriedUids: { [Player]: { string } } = {}
-- Grabbed a mega crate: no more pickups this shift. Value = the floor the lock
-- was acquired on (true when unattributable) so a scoped ClearShift releases
-- only that session's locks (R2 WP4.1).
local megaLocked: { [Player]: Instance | boolean } = {}
local holderLoops: { [Player]: thread } = {}
local firstPickupLogged: { [Player]: boolean } = {}
local casesFolder: Folder? = nil

local caseEventRemote: RemoteEvent? = nil
local noiseMeterRemote: RemoteEvent? = nil

local noiseRng = Random.new()

--------------------------------------------------------------------------------
-- Noise model plumbing (contract §G; NoiseService is a parallel Stage 1 module)
--------------------------------------------------------------------------------

local function getCaseNoiseMult(player: Player): number
	local noise = getSibling("NoiseService")
	if noise ~= nil and type(noise.GetPlayerCaseMult) == "function" then
		local ok, mult = pcall(noise.GetPlayerCaseMult, player)
		if ok and type(mult) == "number" then
			return mult
		end
	end
	return GameConstants.CASE_NOISE_MULT_DEFAULT
end

-- R2 WP4.1: resolves the emitting player's session floor + shift id via the
-- ShiftService facade (feature-detected, pcall-fenced; nils when absent) so
-- noise events can carry session scope for per-session Defect AIs (WP4.2).
local function resolveSessionScope(source: Player?): (Instance?, string?)
	if source == nil then
		return nil, nil
	end
	local shift = getSibling("ShiftService")
	if shift == nil then
		return nil, nil
	end
	local floorRoot: Instance? = nil
	local sessionId: string? = nil
	if type(shift.GetFloorRootFor) == "function" then
		local ok, root = pcall(shift.GetFloorRootFor, source)
		if ok and typeof(root) == "Instance" then
			floorRoot = root
		end
	end
	if type(shift.GetShiftIdFor) == "function" then
		local ok, id = pcall(shift.GetShiftIdFor, source)
		if ok and type(id) == "string" then
			sessionId = id
		end
	end
	return floorRoot, sessionId
end

local function emitNoise(position: Vector3, loudness: number, source: Player?)
	if loudness <= 0 then
		return
	end
	local noise = getSibling("NoiseService")
	if noise ~= nil and type(noise.Emit) == "function" then
		local floorRoot, sessionId = resolveSessionScope(source)
		pcall(noise.Emit, {
			pos = position,
			loudness = loudness,
			source = source,
			floorRoot = floorRoot,
			sessionId = sessionId,
		})
	end
end

-- (moving, sprinting, loudnessMult) from actual horizontal velocity (§G:
-- sprint x2.0, standing still x0.25). The sprint threshold scales by the
-- holder's carry slowdown (CARRY_SPEED_MULT_PER_CASE ^ count) — a sprinting
-- holder moves at SPRINT_SPEED * 0.94^n, which at 3+ cases falls below the
-- unscaled threshold and would never read as sprinting.
local function getLoudnessState(root: BasePart, holder: Player): (boolean, boolean, number)
	local velocity = root.AssemblyLinearVelocity
	local speed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
	local carryMult = if holder:GetAttribute("CarrySpeedExempt") == true
		then 1
		else GameConstants.CARRY_SPEED_MULT_PER_CASE ^ CaseService.GetCarriedCount(holder)
	local moving = speed > MOVING_SPEED_THRESHOLD
	local sprinting = speed > SPRINT_DETECT_SPEED * carryMult
	local mult = if not moving
		then GameConstants.STILL_LOUDNESS_MULT
		elseif sprinting then GameConstants.SPRINT_LOUDNESS_MULT
		else 1
	return moving, sprinting, mult
end

local function fireNoiseMeter(player: Player, noise01: number, carriedCount: number)
	-- NoiseService owns the NoiseMeter remote when present (it recomputes from
	-- our GetCarriedCount/GetMaxCarry — its doc asks us to PushMeter after
	-- pickup/drop). Only fire the remote directly when running without it.
	local noise = getSibling("NoiseService")
	if noise ~= nil and type(noise.PushMeter) == "function" then
		pcall(noise.PushMeter, player)
		return
	end
	if noiseMeterRemote ~= nil then
		noiseMeterRemote:FireClient(player, {
			noise01 = noise01,
			carriedCount = carriedCount,
			maxCarry = CaseService.GetMaxCarry(player),
		})
	end
end

-- Recomputes and pushes the meter after a carriedCount change (pickup, drop,
-- steal, bank, scatter, loss).
local function pushMeterFor(player: Player)
	if player.Parent == nil then
		return
	end
	local count = CaseService.GetCarriedCount(player)
	fireNoiseMeter(player, Util.Clamp01(count * GameConstants.NOISE_PER_CARRIED_CASE), count)
end

local function fireCaseEvent(kind: string, record: CaseRecord, holderUserId: number?)
	if caseEventRemote ~= nil then
		caseEventRemote:FireAllClients({
			kind = kind,
			caseUid = record.uid,
			tier = record.tier,
			holderUserId = holderUserId,
		})
	end
end

--------------------------------------------------------------------------------
-- Carry capacity & speed (contract I)
--------------------------------------------------------------------------------

-- BASE_CARRY_SLOTS + 2 with PASS_CARRY, via safe pcall-require defaulting false.
function CaseService.GetMaxCarry(player: Player): number
	local bonus = 0
	local monetization = getSibling("MonetizationService")
	if monetization ~= nil and type(monetization.OwnsPass) == "function" then
		local ok, owns = pcall(monetization.OwnsPass, player, "PASS_CARRY")
		if ok and owns == true then
			bonus = GameConstants.PASS_CARRY_BONUS
		end
	end
	-- Equipped-pet carry perk ("PetCarryBonus" attribute, published by
	-- PetService): stack more boxes per run. Floored — slots are whole.
	local petCarry = tonumber(player:GetAttribute("PetCarryBonus")) or 0
	if petCarry > 0 then
		bonus += math.floor(petCarry)
	end
	return GameConstants.BASE_CARRY_SLOTS + bonus
end

function CaseService.GetCarriedCount(player: Player): number
	local list = carriedUids[player]
	return if list ~= nil then #list else 0
end

function CaseService.GetCarried(player: Player): { { uid: string, tier: number } }
	local result: { { uid: string, tier: number } } = {}
	local list = carriedUids[player]
	if list ~= nil then
		for _, uid in list do
			local record = cases[uid]
			if record ~= nil then
				table.insert(result, { uid = record.uid, tier = record.tier })
			end
		end
	end
	return result
end

-- World position of a live case by uid (the case model lives under the cases
-- folder, NOT the floor model, and the uid attribute is on the Model — so this
-- is the safe way for a server caller, e.g. the intro floor, to locate a box).
-- Returns nil if the uid is unknown / already despawned.
function CaseService.GetCasePosition(uid: string): Vector3?
	local record = cases[uid]
	if record == nil or record.model == nil then
		return nil
	end
	return record.model:GetPivot().Position
end

-- WalkSpeed = (WALKSPEED_BASE + petSpeed) * bikeMult * carryMult — the server
-- WalkSpeed owner's unified formula (R3-5, Addendum 2; R3 plan decision §6).
-- Three factors:
--   * petSpeed  — additive "PetSpeedBonus" attribute (PetService).
--   * bikeMult  — BIKE_SPEED_MULT while the server-set "BikeActive" attribute
--     is true (BikeService's display/speed mirror; the bike is lobby-only and
--     always cleared where carry happens, but the unified formula keeps both
--     WalkSpeed owners agreed anyway).
--   * carryMult — CARRY_SPEED_MULT_PER_CASE ^ carriedCount (§G); the
--     "CarrySpeedExempt" player attribute (Steady Grips consumable, run-scoped
--     by ConsumableService) skips the carry penalty entirely.
-- The client WalkSpeed owner (InputController.applyWalkSpeed) mirrors this
-- with max(sprint path, bike path) precedence — bike NEVER stacks with sprint
-- — then applies the same carry penalty, so both owners always agree.
function CaseService.ApplyCarrySpeed(player: Player)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil then
		return
	end
	local count = CaseService.GetCarriedCount(player)
	local mult = if player:GetAttribute("CarrySpeedExempt") == true
		then 1
		else GameConstants.CARRY_SPEED_MULT_PER_CASE ^ count
	local petSpeed = tonumber(player:GetAttribute("PetSpeedBonus")) or 0
	-- R3-5 lobby bicycle factor (the one new local — R3 plan decision §6).
	local bikeMult = if player:GetAttribute("BikeActive") == true then GameConstants.BIKE_SPEED_MULT else 1
	humanoid.WalkSpeed = (GameConstants.WALKSPEED_BASE + petSpeed) * bikeMult * mult
end

--------------------------------------------------------------------------------
-- Case model construction (greybox box + tier-colored stripe)
--------------------------------------------------------------------------------

local function ensureCasesFolder(): Folder
	if casesFolder ~= nil and casesFolder.Parent ~= nil then
		return casesFolder
	end
	local folder = Instance.new("Folder")
	folder.Name = "NightShiftCases"
	folder.Parent = Workspace
	casesFolder = folder
	return folder
end

-- Ground-snaps `position`; also returns the raycast hit instance so callers can
-- attribute the spot to a session floor (R2 WP4.1 — see resolveFloorRootFrom).
local function findGroundHit(position: Vector3): (Vector3, Instance?)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local exclude: { Instance } = {}
	if casesFolder ~= nil then
		table.insert(exclude, casesFolder)
	end
	for _, player in Players:GetPlayers() do
		if player.Character ~= nil then
			table.insert(exclude, player.Character)
		end
	end
	params.FilterDescendantsInstances = exclude

	local result = Workspace:Raycast(position + Vector3.new(0, 6, 0), Vector3.new(0, -60, 0), params)
	if result ~= nil then
		return result.Position + Vector3.new(0, CASE_BODY_SIZE.Y / 2 + 0.05, 0), result.Instance
	end
	return position, nil
end

local function findGround(position: Vector3): Vector3
	local snapped = findGroundHit(position)
	return snapped
end

-- Resolves the session floor that owns `instance` (R2 WP4.1): nearest ancestor
-- Model carrying FloorGenService's "SessionId" attribute, else a floor already
-- registered by SpawnForShift (covers the legacy fallback floor, which carries
-- no attribute). Returns nil when the spot is unattributable.
local function resolveFloorRootFrom(instance: Instance?): Instance?
	local node: Instance? = instance
	while node ~= nil and node ~= game do
		if node:IsA("Model") and node:GetAttribute("SessionId") ~= nil then
			return node
		end
		node = node.Parent
	end
	if instance ~= nil then
		for _, record in cases do
			local root = record.floorRoot
			if root ~= nil and instance:IsDescendantOf(root) then
				return root
			end
		end
	end
	return nil
end

local function createCase(tier: number, position: Vector3, yaw: number, golden: boolean?, mega: boolean?): CaseRecord
	local uid = HttpService:GenerateGUID(false)

	local model = Instance.new("Model")
	model.Name = if mega == true then "MegaCase" else "Case"
	model:SetAttribute("CaseUid", uid)
	model:SetAttribute("CaseTier", tier)
	model:SetAttribute(ATTR_CASE_UID, uid) -- client InputController targeting contract
	if mega == true then
		model:SetAttribute("MegaCase", true)
	end
	CollectionService:AddTag(model, TAG_CASE)

	local baseCFrame = CFrame.new(position) * CFrame.Angles(0, yaw, 0)
	-- Mega crate is oversized — far bigger than any normal crate.
	local bodySize = if mega == true then CASE_BODY_SIZE * 2.4 else CASE_BODY_SIZE
	local stripeSize = if mega == true then CASE_STRIPE_SIZE * 2.4 else CASE_STRIPE_SIZE

	local body = Instance.new("Part")
	body.Name = "Body"
	body.Size = bodySize
	body.CFrame = baseCFrame
	body.Anchored = true
	body.Color = CASE_BODY_COLOR
	body.TopSurface = Enum.SurfaceType.Smooth
	body.BottomSurface = Enum.SurfaceType.Smooth
	body.Parent = model

	local stripe = Instance.new("Part")
	stripe.Name = "Stripe"
	stripe.Size = stripeSize
	stripe.CFrame = baseCFrame * CFrame.new(0, 0.45 * (if mega == true then 2.4 else 1), 0)
	stripe.Anchored = false
	stripe.CanCollide = false
	stripe.Massless = true
	stripe.Color = TIER_STRIPE_COLORS[tier] or TIER_STRIPE_COLORS[1]
	stripe.TopSurface = Enum.SurfaceType.Smooth
	stripe.BottomSurface = Enum.SurfaceType.Smooth
	stripe.Parent = model

	local stripeWeld = Instance.new("WeldConstraint")
	stripeWeld.Part0 = body
	stripeWeld.Part1 = stripe
	stripeWeld.Parent = stripe

	-- Case glow ladder: the rarer the crate, the brighter it burns in the
	-- dark (the tier-6 rainbow box below flashes AND outshines everything).
	if tier >= 3 and tier <= 5 and golden ~= true then
		local glow = Instance.new("PointLight")
		glow.Color = TIER_STRIPE_COLORS[tier] or TIER_STRIPE_COLORS[3]
		glow.Brightness = ({ 0.6, 1.2, 2 })[tier - 2]
		glow.Range = ({ 8, 12, 14 })[tier - 2]
		glow.Parent = body
		if tier >= 4 then
			stripe.Material = Enum.Material.Neon -- T4/T5 stripes burn neon too
		end
	end

	-- Golden case (§G GOLDEN_CASE_CHANCE): glowing showcase spawn. Always a
	-- Tier 3 stub (callers force the tier), styled so it reads across a dark
	-- room — neon gold body + warm light.
	if golden == true then
		model:SetAttribute("GoldenCase", true)
		body.Color = Color3.fromRGB(235, 190, 52)
		body.Material = Enum.Material.Neon
		stripe.Color = Color3.fromRGB(255, 240, 180)
		local light = Instance.new("PointLight")
		light.Color = Color3.fromRGB(255, 210, 90)
		light.Brightness = 2
		light.Range = 14
		light.Parent = body
	end

	-- Sealed-case tell (collectible redesign): Tier 3+ cases carry a thin neon
	-- seam strip along the top edge in the tier color — readable across a
	-- dark room, zero runtime cost (static part, no tween). Golden cases
	-- already glow (above) and the tier-6 rainbow box hue-cycles (below), so
	-- both skip it; tiers 1-2 stay plain.
	if tier >= 3 and tier <= 5 and golden ~= true then
		local seam = Instance.new("Part")
		seam.Name = "Seam"
		seam.Size = Vector3.new(CASE_BODY_SIZE.X + 0.1, 0.08, 0.25)
		seam.CFrame = baseCFrame * CFrame.new(0, CASE_BODY_SIZE.Y / 2 + 0.04, 0)
		seam.Anchored = false
		seam.CanCollide = false
		seam.Massless = true
		seam.Color = TIER_STRIPE_COLORS[tier] or TIER_STRIPE_COLORS[3]
		seam.Material = Enum.Material.Neon
		seam.TopSurface = Enum.SurfaceType.Smooth
		seam.BottomSurface = Enum.SurfaceType.Smooth
		seam.Parent = model
		local seamWeld = Instance.new("WeldConstraint")
		seamWeld.Part0 = body
		seamWeld.Part1 = seam
		seamWeld.Parent = seam
	end

	-- Rainbow box (tier 6, §G RAINBOW_CASE_CHANCE): hue-cycling neon — the
	-- one-in-a-hundred-shifts jackpot crate; rolls Legendary+ only when opened.
	if tier == 6 and mega ~= true then
		body.Material = Enum.Material.Neon
		local light = Instance.new("PointLight")
		light.Brightness = 3 -- top of the glow ladder: nothing burns brighter
		light.Range = 18
		light.Parent = body
		task.spawn(function()
			while body.Parent ~= nil do
				local hue = (os.clock() * 0.25) % 1
				local color = Color3.fromHSV(hue, 0.7, 1)
				body.Color = color
				stripe.Color = Color3.fromHSV((hue + 0.3) % 1, 0.7, 1)
				light.Color = color
				task.wait(0.1)
			end
		end)
	end

	-- Mega crate: an enormous, blindingly bright glowing-purple beacon — visible
	-- from across the whole floor. Guarantees a Mythical when opened.
	if mega == true then
		local PURPLE = Color3.fromRGB(170, 40, 255)
		body.Material = Enum.Material.Neon
		body.Color = PURPLE
		stripe.Material = Enum.Material.Neon
		stripe.Color = Color3.fromRGB(220, 150, 255)
		local light = Instance.new("PointLight")
		light.Color = PURPLE
		light.Brightness = 8 -- far brighter than anything else in the dark
		light.Range = 40
		light.Parent = body
		-- A slow pulse so it reads as "the big one" even at a glance.
		task.spawn(function()
			while body.Parent ~= nil do
				light.Brightness = 6 + math.sin(os.clock() * 2) * 2
				task.wait(0.1)
			end
		end)
	end

	model.PrimaryPart = body
	model.Parent = ensureCasesFolder()

	local record: CaseRecord = {
		uid = uid,
		tier = tier,
		model = model,
		body = body,
		state = "world",
		holder = nil,
		baseCFrame = baseCFrame,
		carryWeld = nil,
		squirmThread = nil,
		mega = mega == true or nil,
		floorRoot = nil, -- stamped by SpawnForShift / SpawnCaseAt (R2 WP4.1)
		guaranteedRarity = nil, -- set by SpawnCaseAt's optional 3rd arg (intro floor)
	}
	cases[uid] = record
	return record
end

--------------------------------------------------------------------------------
-- Attach / detach
--------------------------------------------------------------------------------

local function carryOffset(index: number): CFrame
	return CFrame.new(0, (index - 1) * CARRY_STACK_STEP_STUDS, CARRY_BACK_OFFSET_STUDS + CASE_BODY_SIZE.Z / 2)
end

local function stopSquirm(record: CaseRecord)
	if record.squirmThread ~= nil then
		pcall(task.cancel, record.squirmThread)
		record.squirmThread = nil
	end
end

-- Squirm loop (§G): every random 8-15s the carried case emits a NoiseEvent at
-- loudness 0.35 * tier, scaled by sprint/still and the holder's case-noise mult
-- (scent spray sets that to 0 for the run).
local function startSquirm(record: CaseRecord)
	if record.squirmThread ~= nil then
		return
	end
	record.squirmThread = task.spawn(function()
		while true do
			task.wait(
				noiseRng:NextNumber(
					GameConstants.SQUIRM_INTERVAL_MIN_SECONDS,
					GameConstants.SQUIRM_INTERVAL_MAX_SECONDS
				)
			)
			if record.state ~= "carried" or record.holder == nil then
				break
			end
			local holder = record.holder :: Player
			local character = holder.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if root ~= nil and root:IsA("BasePart") then
				local _, _, stateMult = getLoudnessState(root, holder)
				local loudness = GameConstants.SQUIRM_LOUDNESS_PER_TIER
					* record.tier
					* stateMult
					* getCaseNoiseMult(holder)
				emitNoise(root.Position, loudness, holder)
			end
		end
		record.squirmThread = nil
	end)
end

local function attachToCharacter(record: CaseRecord, player: Player, index: number): boolean
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root == nil or not root:IsA("BasePart") then
		return false
	end

	-- Invisible while carried: CarryController renders the visible stack on the
	-- holder client-side from CaseEvent (single visual source of truth). The
	-- server model stays welded for authoritative position/steal validation.
	for _, part in record.model:GetDescendants() do
		if part:IsA("BasePart") then
			part.Anchored = false
			part.CanCollide = false
			part.Massless = true
			part.Transparency = 1
		end
	end
	record.model:PivotTo(root.CFrame * carryOffset(index))

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = root
	weld.Part1 = record.body
	weld.Parent = record.body

	record.carryWeld = weld
	record.state = "carried"
	record.holder = player
	record.baseCFrame = nil
	-- Parent under the character: the client treats "descendant of a character"
	-- as carried (skips it for pickup targeting), and the stack despawns
	-- naturally if the character is removed out from under us.
	record.model.Parent = character
	startSquirm(record)
	return true
end

local function detachFromHolder(record: CaseRecord)
	if record.carryWeld ~= nil then
		record.carryWeld:Destroy()
		record.carryWeld = nil
	end
	stopSquirm(record)
	record.holder = nil
end

-- Drops the record into the world at/near `position` (ground-snapped, wobble re-enabled).
local function placeInWorld(record: CaseRecord, position: Vector3)
	detachFromHolder(record)
	record.state = "world"
	local baseCFrame = CFrame.new(findGround(position)) * CFrame.Angles(0, noiseRng:NextNumber(0, math.pi * 2), 0)
	record.baseCFrame = baseCFrame
	for _, part in record.model:GetDescendants() do
		if part:IsA("BasePart") then
			part.Transparency = 0
		end
	end
	record.body.Anchored = true
	record.body.CanCollide = true
	record.model:PivotTo(baseCFrame)
	record.model.Parent = ensureCasesFolder()
end

local function destroyRecord(record: CaseRecord)
	detachFromHolder(record)
	cases[record.uid] = nil
	record.model:Destroy()
end

-- Removes a uid from a player's carried list and re-stacks the remaining welds.
local function removeFromCarriedList(player: Player, uid: string)
	local list = carriedUids[player]
	if list == nil then
		return
	end
	local at = table.find(list, uid)
	if at ~= nil then
		table.remove(list, at)
	end
	if #list == 0 then
		carriedUids[player] = nil
	else
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root ~= nil and root:IsA("BasePart") then
			for index, carriedUid in list do
				local record = cases[carriedUid]
				if record ~= nil and record.state == "carried" then
					if record.carryWeld ~= nil then
						record.carryWeld:Destroy()
					end
					record.model:PivotTo((root :: BasePart).CFrame * carryOffset(index))
					local weld = Instance.new("WeldConstraint")
					weld.Part0 = root
					weld.Part1 = record.body
					weld.Parent = record.body
					record.carryWeld = weld
				end
			end
		end
	end
	CaseService.ApplyCarrySpeed(player)
	pushMeterFor(player)
end

-- Destroys one record wherever it lives (world or carried), keeping the
-- holder's stack/welds/meter consistent — the scoped-clear unit of work
-- (R2 WP4.1).
local function clearRecord(record: CaseRecord)
	local holder = if record.state == "carried" then record.holder else nil
	local uid = record.uid
	destroyRecord(record)
	if holder ~= nil then
		removeFromCarriedList(holder, uid)
	end
end

-- Sweeps records whose model or stamped floor has already left the world
-- (defensive: a session teardown should have cleared them via the scoped
-- ClearShift; this catches anything that slipped past it).
local function clearOrphanedRecords()
	local orphaned: { CaseRecord } = {}
	for _, record in cases do
		local root = record.floorRoot
		if record.model.Parent == nil or (root ~= nil and not root:IsDescendantOf(game)) then
			table.insert(orphaned, record)
		end
	end
	for _, record in orphaned do
		clearRecord(record)
	end
end

--------------------------------------------------------------------------------
-- Per-holder noise loop (meter + movement contribution; §G greed dial)
--------------------------------------------------------------------------------

local function ensureHolderLoop(player: Player)
	if holderLoops[player] ~= nil then
		return
	end
	holderLoops[player] = task.spawn(function()
		local movementAccumulator = 0
		local lastNoise01 = -1
		local lastCount = -1
		while true do
			task.wait(NOISE_METER_INTERVAL_SECONDS)
			local list = carriedUids[player]
			if list == nil or #list == 0 or player.Parent == nil then
				break
			end
			local character = player.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if root == nil or not root:IsA("BasePart") then
				continue
			end

			local moving, sprinting, stateMult = getLoudnessState(root, player)
			local count = #list
			local noise01 = Util.Clamp01(count * GameConstants.NOISE_PER_CARRIED_CASE * stateMult)
			if math.abs(noise01 - lastNoise01) > 0.005 or count ~= lastCount then
				lastNoise01 = noise01
				lastCount = count
				fireNoiseMeter(player, noise01, count)
			end

			-- Movement contribution to the world (Defect hearing): periodic
			-- NoiseEvents while moving with cases, sprint x2.
			if moving then
				movementAccumulator += NOISE_METER_INTERVAL_SECONDS
				if movementAccumulator >= MOVEMENT_EMIT_INTERVAL_SECONDS then
					movementAccumulator = 0
					local loudness = count
						* GameConstants.NOISE_PER_CARRIED_CASE
						* (if sprinting then GameConstants.SPRINT_LOUDNESS_MULT else 1)
						* getCaseNoiseMult(player)
					emitNoise(root.Position, loudness, player)
				end
			else
				movementAccumulator = 0
			end
		end
		holderLoops[player] = nil
		pushMeterFor(player)
	end)
end

--------------------------------------------------------------------------------
-- Shift lifecycle (called by ShiftService)
--------------------------------------------------------------------------------

-- Six case tiers, distance-weighted (§playtest spec): tier odds per anchor
-- scale with distance from the extraction dock — near the dock it's nearly
-- all T1/T2; T4 lives in the deep floor; T5 averages well under one per
-- floor, so it statistically skips many games entirely. T6 is the rainbow
-- box's own 1-in-100-shifts event (never rolled here).
local TIER_BANDS: { { maxDist: number, weights: { number } } } = {
	{ maxDist = 80, weights = { 70, 25, 5, 0, 0 } },
	{ maxDist = 160, weights = { 30, 40, 25, 4.5, 0.5 } },
	{ maxDist = math.huge, weights = { 10, 30, 40, 17, 3 } },
}

local function rollTierForDistance(rng: Random, distance: number): number
	local weights = TIER_BANDS[#TIER_BANDS].weights
	for _, band in TIER_BANDS do
		if distance <= band.maxDist then
			weights = band.weights
			break
		end
	end
	local total = 0
	for _, weight in weights do
		total += weight
	end
	local roll = rng:NextNumber() * total
	local cumulative = 0
	for tier, weight in weights do
		cumulative += weight
		if roll < cumulative then
			return tier
		end
	end
	return 1
end

local function dockPosition(anchors: { BasePart }): Vector3
	local floorGen = getSibling("FloorGenService")
	if floorGen ~= nil and type(floorGen.GetExtractZone) == "function" then
		local ok, zone = pcall(floorGen.GetExtractZone)
		if ok and zone ~= nil and zone:IsA("BasePart") then
			return zone.Position
		end
	end
	-- Fallback: south edge of the anchor field (the dock cell is mid-south).
	local sumX, minZ = 0, math.huge
	for _, anchor in anchors do
		sumX += anchor.Position.X
		minZ = math.min(minZ, anchor.Position.Z)
	end
	return Vector3.new(sumX / #anchors, 0, minZ - 18)
end

-- Spawns cases at 60% of the floor's tagged anchors. Anchor selection and tier
-- rolls are driven by the shift's seeded rng (deterministic per floorSeed).
function CaseService.SpawnForShift(floorRoot: Instance, rng: Random)
	-- R2 WP4.1: clear only THIS floor's leftovers — with concurrent sessions a
	-- new dispatch must never destroy another live floor's cases — plus any
	-- records orphaned by an already-gone floor.
	CaseService.ClearShift(floorRoot)
	clearOrphanedRecords()

	local anchors: { BasePart } = {}
	for _, instance in CollectionService:GetTagged(TAG_CASE_ANCHOR) do
		if instance:IsA("BasePart") and instance:IsDescendantOf(floorRoot) then
			table.insert(anchors, instance)
		end
	end
	if #anchors == 0 then
		warn("[CaseService] floor has no tagged CaseAnchor parts — no cases spawned")
		return
	end

	-- Deterministic order regardless of GetTagged ordering, then a seeded shuffle.
	table.sort(anchors, function(a, b)
		local pa, pb = a.Position, b.Position
		if pa.X ~= pb.X then
			return pa.X < pb.X
		end
		if pa.Z ~= pb.Z then
			return pa.Z < pb.Z
		end
		return pa.Y < pb.Y
	end)
	for index = #anchors, 2, -1 do
		local swap = rng:NextInteger(1, index)
		anchors[index], anchors[swap] = anchors[swap], anchors[index]
	end

	local fillCount = math.clamp(math.ceil(#anchors * CASE_ANCHOR_FILL), 1, #anchors)
	local dock = dockPosition(anchors)

	-- §3.2 time-to-fun guarantee: the filled anchor nearest the dock is ALWAYS
	-- a Tier 1 (the rest roll their distance band).
	local nearestIndex, nearestDist = 1, math.huge
	for index = 1, fillCount do
		local d = (anchors[index].Position - dock).Magnitude
		if d < nearestDist then
			nearestIndex, nearestDist = index, d
		end
	end

	for index = 1, fillCount do
		local anchor = anchors[index]
		local distance = (anchor.Position - dock).Magnitude
		local tier = if index == nearestIndex then 1 else rollTierForDistance(rng, distance)
		-- Super-rare golden spawn: glowing, and always exactly a Tier 3 case
		-- wherever it lands (the disclosed golden contract — GameConstants §G;
		-- createCase expects its callers to force the tier).
		local golden = rng:NextNumber() < GameConstants.GOLDEN_CASE_CHANCE
		if golden then
			tier = 3
		end
		local record =
			createCase(tier, anchor.Position + Vector3.new(0, 1.3, 0), rng:NextNumber(0, math.pi * 2), golden)
		record.floorRoot = floorRoot
	end

	-- Rainbow box (TIER 6 — the best crate in the game): ~1 in 100 shifts, at
	-- most one per floor, dropped at the FARTHEST unfilled anchor from the
	-- dock — if it spawned, you earn the walk.
	if rng:NextNumber() < GameConstants.RAINBOW_CASE_CHANCE and fillCount < #anchors then
		local best: BasePart? = nil
		local bestDist = -1
		for index = fillCount + 1, #anchors do
			local d = (anchors[index].Position - dock).Magnitude
			if d > bestDist then
				best, bestDist = anchors[index], d
			end
		end
		if best ~= nil then
			local record = createCase(6, best.Position + Vector3.new(0, 1.3, 0), rng:NextNumber(0, math.pi * 2))
			record.floorRoot = floorRoot
		end
	end

	-- Mega crate (§G MEGA_CASE_CHANCE): ~1 in 10,000 shifts, at most one, at the
	-- farthest free anchor — a guaranteed Mythical for whoever dares haul it out
	-- (grabbing it drops all your other boxes and locks you out of more).
	if rng:NextNumber() < GameConstants.MEGA_CASE_CHANCE then
		local best: BasePart? = nil
		local bestDist = -1
		for index = fillCount + 1, #anchors do
			local d = (anchors[index].Position - dock).Magnitude
			if d > bestDist then
				best, bestDist = anchors[index], d
			end
		end
		local spot = if best ~= nil then best else anchors[#anchors]
		if spot ~= nil then
			local record =
				createCase(6, spot.Position + Vector3.new(0, 1.8, 0), rng:NextNumber(0, math.pi * 2), false, true)
			record.floorRoot = floorRoot
		end
	end
end

-- Spawns ONE registered world case at `position` (ground-snapped), outside the
-- shift-start anchor flow. Stage 6 integration: ConsumableService's Foreman's
-- Key vault case (feature-detected: SpawnCaseAt/SpawnExternalCase/...). The
-- case goes through createCase, so pickup/steal-from-downed, banking
-- (TakeAllCarried) and ClearShift teardown all work natively. Returns the new
-- case uid, or nil on invalid input. The optional 3rd arg guaranteedRarity
-- (intro floor) stamps record.guaranteedRarity so TakeAllCarried can force the
-- rarity this case opens into; 2-arg callers are byte-unchanged in behavior.
function CaseService.SpawnCaseAt(tier: number, position: Vector3, guaranteedRarity: string?): string?
	if type(tier) ~= "number" or tier < 1 or tier > 6 or typeof(position) ~= "Vector3" then
		return nil
	end
	local groundPosition, hit = findGroundHit(position)
	local record = createCase(math.floor(tier), groundPosition, noiseRng:NextNumber(0, math.pi * 2))
	-- R2 WP4.1: attribute the case to its session floor via the ground hit so a
	-- scoped ClearShift tears it down with the right session.
	record.floorRoot = resolveFloorRootFrom(hit)
	if type(guaranteedRarity) == "string" then
		record.guaranteedRarity = guaranteedRarity
	end
	return record.uid
end

-- Destroys live cases and resets carry state. nil floorRoot keeps the legacy
-- clear-everything behavior (single-session/global paths). A non-nil floorRoot
-- (R2 WP4.1 — ShiftSession teardown, SpawnForShift) clears ONLY the records
-- stamped to that floor so concurrent sessions' cases survive. Unattributed
-- (nil-stamped) strays are also taken by a scoped clear: destroying beats
-- leaking, and every normally-spawned record is stamped at
-- SpawnForShift/SpawnCaseAt.
function CaseService.ClearShift(floorRoot: Instance?)
	if floorRoot == nil then
		for _, record in cases do
			stopSquirm(record)
			record.model:Destroy()
		end
		table.clear(cases)

		for player in carriedUids do
			carriedUids[player] = nil
			CaseService.ApplyCarrySpeed(player)
			pushMeterFor(player)
		end
		table.clear(megaLocked) -- the carry lock is per-shift only
		-- holder loops exit on their next tick (their carried lists are now empty)
		return
	end

	local toClear: { CaseRecord } = {}
	for _, record in cases do
		if record.floorRoot == floorRoot or record.floorRoot == nil then
			table.insert(toClear, record)
		end
	end
	for _, record in toClear do
		clearRecord(record)
	end
	for player, lock in megaLocked do
		if lock == floorRoot then
			megaLocked[player] = nil -- that shift is over; the lock dies with it
		end
	end
end

--------------------------------------------------------------------------------
-- Bank / scatter / lose (ExtractionService and ShiftService entry points)
--------------------------------------------------------------------------------

-- Extraction banking: removes and destroys every carried case, firing CaseEvent
-- "Banked" per case, and returns { {uid, tier} } for CaseStub creation.
function CaseService.TakeAllCarried(
	player: Player
): { { uid: string, tier: number, mega: boolean?, guaranteedRarity: string? } }
	local taken: { { uid: string, tier: number, mega: boolean?, guaranteedRarity: string? } } = {}
	local list = carriedUids[player]
	if list ~= nil then
		carriedUids[player] = nil
		for _, uid in list do
			local record = cases[uid]
			if record ~= nil then
				table.insert(taken, {
					uid = record.uid,
					tier = record.tier,
					mega = record.mega,
					guaranteedRarity = record.guaranteedRarity,
				})
				fireCaseEvent("Banked", record, player.UserId)
				destroyRecord(record)
			end
		end
	end
	CaseService.ApplyCarrySpeed(player)
	pushMeterFor(player)
	return taken
end

-- Death: carried cases scatter around `position` as world pickups (§1.2 — the
-- crew can still carry the haul out). Returns how many scattered.
function CaseService.ScatterCarried(player: Player, position: Vector3): number
	local count = 0
	local list = carriedUids[player]
	if list ~= nil then
		carriedUids[player] = nil
		for _, uid in list do
			local record = cases[uid]
			if record ~= nil then
				local angle = noiseRng:NextNumber(0, math.pi * 2)
				local radius = noiseRng:NextNumber(2, 5)
				placeInWorld(record, position + Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius))
				fireCaseEvent("Dropped", record, nil)
				count += 1
			end
		end
	end
	CaseService.ApplyCarrySpeed(player)
	pushMeterFor(player)
	return count
end

-- Shift-end loss: un-extracted carried cases are simply gone. Fires CaseEvent
-- "Lost" per case so clients drop their stack renders. Returns the count
-- (ShiftService reports it via death{casesLost} analytics).
function CaseService.LoseCarried(player: Player): number
	local count = 0
	local list = carriedUids[player]
	if list ~= nil then
		carriedUids[player] = nil
		for _, uid in list do
			local record = cases[uid]
			if record ~= nil then
				fireCaseEvent("Lost", record, player.UserId)
				destroyRecord(record)
				count += 1
			end
		end
	end
	CaseService.ApplyCarrySpeed(player)
	pushMeterFor(player)
	return count
end

--------------------------------------------------------------------------------
-- Remote handlers
--------------------------------------------------------------------------------

-- Post-validation pickup commit: welds the case to `player`, inserts it into
-- their carried list, fires the pickup CaseEvent the client CarryController
-- renders the visible carried stack from, re-applies carry speed and pushes the
-- noise meter. Shared by onRequestPickup (after its gates) and ServerPickup
-- (server-authoritative intro floor). Returns false if the weld attach failed
-- (character vanished mid-call), in which case the case is returned to the
-- world. Assumes the caller has already validated record/range/state.
local function commitPickup(player: Player, record: CaseRecord): boolean
	local casePosition = record.model:GetPivot().Position

	-- Grabbing the mega crate drops every other box you're holding (it fills your
	-- arms) and locks you out of further pickups for the rest of the shift.
	if record.mega == true then
		CaseService.ScatterCarried(player, casePosition)
	end

	local list = carriedUids[player]
	local count = if list ~= nil then #list else 0

	-- Transfer off a downed holder, or lift from the world.
	if record.state == "carried" then
		local holder = record.holder :: Player
		detachFromHolder(record)
		removeFromCarriedList(holder, record.uid)
		list = carriedUids[player]
		count = if list ~= nil then #list else 0
	end

	if not attachToCharacter(record, player, count + 1) then
		-- Attach failed (character vanished mid-call): return the case to the world.
		placeInWorld(record, casePosition)
		return false
	end

	if list == nil then
		list = {}
		carriedUids[player] = list
	end
	table.insert(list :: { string }, record.uid)
	if record.mega == true then
		-- No more pickups this shift; stamp the lock with the case's floor so
		-- a scoped ClearShift releases it with the right session (R2 WP4.1).
		megaLocked[player] = record.floorRoot or true
	end
	CaseService.ApplyCarrySpeed(player)
	ensureHolderLoop(player)
	pushMeterFor(player)

	fireCaseEvent("PickedUp", record, player.UserId)
	track(player, "case_pickup", { tier = record.tier })
	if not firstPickupLogged[player] then
		firstPickupLogged[player] = true
		funnelStep(player, 2, "first_case_pickup") -- CoreLoop funnel step 2 (§3.4)
	end
	return true
end

local function onRequestPickup(player: Player, caseUid: any): { [string]: any }
	if type(caseUid) ~= "string" then
		return { ok = false, err = "BAD_ARG" }
	end

	local shift = getSibling("ShiftService")
	if shift == nil then
		return { ok = false, err = "NOT_ACTIVE" }
	end

	-- R2 WP4.1 session scoping: prefer the facade's GetSessionOf (a player with
	-- no session of their own can never handle cases, regardless of how many
	-- OTHER sessions are live) and capture their session floor for the
	-- cross-floor block below. Degrades to the legacy global IsActive gate when
	-- the additive API is absent (house rule).
	local sessionFloor: Instance? = nil
	local sessionScoped = false
	if type(shift.GetSessionOf) == "function" then
		local okSession, session = pcall(shift.GetSessionOf, player)
		if okSession then
			sessionScoped = true
			if session == nil then
				return { ok = false, err = "NOT_ACTIVE" }
			end
			if type(shift.GetFloorRootFor) == "function" then
				local okFloor, floor = pcall(shift.GetFloorRootFor, player)
				if okFloor and typeof(floor) == "Instance" then
					sessionFloor = floor
				end
			end
		end
	end
	if not sessionScoped and (type(shift.IsActive) ~= "function" or not shift.IsActive()) then
		return { ok = false, err = "NOT_ACTIVE" }
	end

	local record = cases[caseUid]
	if record == nil then
		return { ok = false, err = "NOT_FOUND" }
	end

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if character == nil or humanoid == nil or humanoid.Health <= 0 or root == nil or not root:IsA("BasePart") then
		return { ok = false, err = "DEAD" }
	end
	if type(shift.IsDowned) == "function" and shift.IsDowned(player) then
		return { ok = false, err = "DOWNED" }
	end
	-- Only live, un-extracted SHIFT PARTICIPANTS may handle cases. Without this
	-- gate an exploiter could teleport a hub-idling (or already-extracted)
	-- character onto the floor and lift the crew's haul — they could never bank
	-- it (ExtractionService checks IsParticipant), but they could grief it away.
	if type(shift.IsParticipant) == "function" and not shift.IsParticipant(player) then
		return { ok = false, err = "NOT_PARTICIPANT" }
	end
	if type(shift.HasExtracted) == "function" and shift.HasExtracted(player) then
		return { ok = false, err = "NOT_PARTICIPANT" }
	end

	-- R2 WP4.1 cross-floor block: the case must live on the player's OWN
	-- session floor — an exploit-teleported character standing next to a case
	-- 2000 studs away on another session's floor passes the range gate but
	-- fails here. nil-stamped strays fall through to the range gate below.
	if sessionFloor ~= nil and record.floorRoot ~= nil and record.floorRoot ~= sessionFloor then
		return { ok = false, err = "WRONG_FLOOR" }
	end

	-- Carried cases may only be lifted off a DOWNED holder (§1.2: carry out a
	-- downed friend's boxes). Living holders cannot be pickpocketed.
	if record.state == "carried" then
		local holder = record.holder
		if holder == player then
			return { ok = false, err = "ALREADY_HELD" }
		end
		if holder == nil or type(shift.IsDowned) ~= "function" or not shift.IsDowned(holder) then
			return { ok = false, err = "HOLDER_NOT_DOWNED" }
		end
	end

	local casePosition = record.model:GetPivot().Position
	if (root.Position - casePosition).Magnitude > PICKUP_RANGE_STUDS then
		return { ok = false, err = "TOO_FAR" }
	end

	-- Once you've grabbed a mega crate this shift, you can't carry anything else.
	if megaLocked[player] then
		return { ok = false, err = "MEGA_LOCKED" }
	end

	local list = carriedUids[player]
	local count = if list ~= nil then #list else 0
	-- The mega crate ignores the normal carry cap (it's the only thing you hold).
	if record.mega ~= true and count >= CaseService.GetMaxCarry(player) then
		return { ok = false, err = "CARRY_FULL" }
	end

	-- All gates passed: commit the carry (mega-scatter, transfer-off-downed,
	-- attach, list insert, mega lock, speed/loop/meter, CaseEvent, analytics).
	if not commitPickup(player, record) then
		return { ok = false, err = "DEAD" }
	end
	return { ok = true }
end

-- Server-authoritative pickup for the intro floor (no session/IsParticipant/
-- megaLock/range gating — the intro runner owns placement and proximity). Lifts
-- a world case onto `player` and fires the SAME pickup CaseEvent a normal grab
-- does, so the client CarryController renders the visible carried stack. Returns
-- true on success; false when the record is missing, not a free world case, or
-- the weld attach fails.
function CaseService.ServerPickup(player: Player, uid: string): boolean
	if type(uid) ~= "string" then
		return false
	end
	local record = cases[uid]
	if record == nil or record.state ~= "world" or record.holder ~= nil then
		return false
	end
	return commitPickup(player, record)
end

local function onRequestDrop(player: Player, caseUid: any): { [string]: any }
	if type(caseUid) ~= "string" then
		return { ok = false, err = "BAD_ARG" }
	end
	local record = cases[caseUid]
	if record == nil or record.state ~= "carried" or record.holder ~= player then
		return { ok = false, err = "NOT_HELD" }
	end

	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local dropPosition: Vector3
	if root ~= nil and root:IsA("BasePart") then
		dropPosition = root.Position + root.CFrame.LookVector * 2.5
	else
		dropPosition = record.model:GetPivot().Position
	end

	placeInWorld(record, dropPosition)
	removeFromCarriedList(player, record.uid)

	fireCaseEvent("Dropped", record, player.UserId)
	track(player, "case_dropped")
	return { ok = true }
end

--------------------------------------------------------------------------------
-- Loader lifecycle
--------------------------------------------------------------------------------

function CaseService:Init()
	local ok, err = pcall(function()
		caseEventRemote = Remotes.GetEvent("CaseEvent")
		noiseMeterRemote = Remotes.GetEvent("NoiseMeter")
		Remotes.GetFunction("RequestPickupCase").OnServerInvoke = function(player: Player, caseUid: any)
			return onRequestPickup(player, caseUid)
		end
		Remotes.GetFunction("RequestDropCase").OnServerInvoke = function(player: Player, caseUid: any)
			return onRequestDrop(player, caseUid)
		end
	end)
	if not ok then
		warn(`[CaseService] remote bind failed: {err}`)
	end

	Players.PlayerRemoving:Connect(function(player: Player)
		-- A leaver's haul stays playable: scatter it where they stood (active
		-- shift), otherwise clean it up silently.
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local shift = getSibling("ShiftService")
		-- R2 WP4.1: "in an active shift" means the leaver's OWN session when the
		-- facade exposes it (the global IsActive aggregate would scatter a hub
		-- idler's stale state whenever ANY session is live); legacy otherwise.
		local active = false
		if shift ~= nil and type(shift.GetSessionOf) == "function" then
			local okSession, session = pcall(shift.GetSessionOf, player)
			active = okSession and session ~= nil
		elseif shift ~= nil and type(shift.IsActive) == "function" then
			active = shift.IsActive()
		end
		if active and root ~= nil and root:IsA("BasePart") then
			CaseService.ScatterCarried(player, root.Position)
		else
			CaseService.LoseCarried(player)
		end
		local loop = holderLoops[player]
		if loop ~= nil then
			holderLoops[player] = nil
			pcall(task.cancel, loop)
		end
		firstPickupLogged[player] = nil
		carriedUids[player] = nil
		megaLocked[player] = nil
	end)
end

function CaseService:Start()
	-- World-case squirm jitter: a light CFrame wobble so spawned cases read as
	-- alive even in greybox (anchored pivots, low rate, mobile-safe).
	while true do
		task.wait(WOBBLE_INTERVAL_SECONDS)
		for _, record in cases do
			if record.state == "world" and record.baseCFrame ~= nil and record.model.Parent ~= nil then
				local jitter = CFrame.Angles(
					noiseRng:NextNumber(-WOBBLE_MAX_RADIANS, WOBBLE_MAX_RADIANS),
					noiseRng:NextNumber(-WOBBLE_MAX_RADIANS, WOBBLE_MAX_RADIANS),
					noiseRng:NextNumber(-WOBBLE_MAX_RADIANS, WOBBLE_MAX_RADIANS)
				)
				record.model:PivotTo(
					(record.baseCFrame :: CFrame) * CFrame.new(0, noiseRng:NextNumber(0, 0.08), 0) * jitter
				)
			end
		end
	end
end

return CaseService
