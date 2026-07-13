--!strict
-- CRYPTLINGS: NIGHT SHIFT — Defect hearing AI (Stage 1, SOP §3.1 ①, §1.4;
-- R2 WP4.2: per-session AI, Lobby SOP Addendum 1 Change 6.5).
-- One Defect per LIVE SHIFT SESSION (up to 5 concurrent floors at a 2000-stud
-- slot pitch — one AI object per floor, keyed by floorRoot): an oversized
-- blocky misprint toy (~12 studs, greybox Parts, glowing mismatched eyes,
-- rarity-gold accent) that hunts by sound. FSM (per AI):
--   Patrol      random PatrolNode walk, speed 8
--   Investigate heard a qualifying NoiseEvent (contract G threshold) -> move to
--               the position, 10s sweep, speed 12
--   Chase       target visible via raycast <=25 studs OR 3 qualifying noise
--               hits from the same player within 5s; speed 17; roar + red eyes
--               (the clip-able jump-scare beat, SOP §1.4). Lost after 8s with
--               no sight and no noise.
--   Attack      <=4 studs (planar): DEFECT_ATTACK_DAMAGE per hit (two-hit
--               kill); the hit that exhausts health -> ShiftService.DownPlayer,
--               then Investigate.
--
-- Public API (contract I + shift lifecycle):
--   DefectService.OnShiftActive(floorRoot)   -- ShiftService/ShiftSession, shift
--                                            -- goes Active: builds a per-session
--                                            -- AI (own patrol state, target
--                                            -- memory, noise log) for THAT floor
--                                            -- and spawns its Defect at a far
--                                            -- PatrolNode of that floor
--   DefectService.OnShiftEnded(floorRoot?)   -- tears down that floor's AI only;
--                                            -- nil = all (legacy semantics)
--   DefectService.OnShiftStart / OnShiftEnd  -- legacy lifecycle aliases
--   DefectService.ApplyStagger(seconds?, target?) -> boolean
--       CombatService weapon hits; the additive optional target (Defect model /
--       one of its parts / floor root) scopes the stagger to one session's AI
--   DefectService.PlayFlyby(nearPlayer) -> boolean
--       scripted NON-AGGRO walk past a point ~20 studs from the player, with
--       roar; ignores all noise for its 6s duration and can never down anyone
--       (onboarding "DefectFlyby" beat, SOP §3.2). Routes to the AI on the
--       player's own floor.
--
-- Session scoping (Change 6.5): every target/noise decision is bounded to the
-- AI's own floor. Players resolve through the ShiftService facade
-- (GetFloorRootFor — pcall + feature-detected per the Wave-4 house rule;
-- absent → today's global checks plus a floor-bounds assert). Noise events
-- filter by the WP4.1 floorRoot passthrough when present, else by
-- position-in-bounds (the 2000-stud slot pitch lands any cross-floor position
-- thousands of studs outside the padded box). Catches still route through
-- ShiftService.DownPlayer (the facade maps player -> session).
--
-- PatrolNodes (provided by FloorGen inside the floor model) are discovered in
-- order: CollectionService tag "PatrolNode" filtered by IsDescendantOf(floorRoot)
-- (ancestor-walk — NEVER a global first-match, which grabs the wrong floor
-- with 5 live) -> a "PatrolNodes" folder of BaseParts -> any descendant
-- BasePart named "PatrolNode" -> bounding-box fallback grid (keeps the Defect
-- patrolling even mid-construction).

local CollectionService = game:GetService("CollectionService")
local PathfindingService = game:GetService("PathfindingService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConstants = require(Shared:WaitForChild("Config"):WaitForChild("GameConstants"))

local NoiseService = require(script.Parent:WaitForChild("NoiseService"))

--------------------------------------------------------------------------------
-- Tuning (defect-ai spec of record; shared noise numbers live in GameConstants)
--------------------------------------------------------------------------------

-- Patrol/investigate/chase speeds and attack damage live per-variant now (see
-- VARIANTS below; Red is the original 8/12/17/50 baseline).
local ATTACK_RANGE_STUDS = 4
local SIGHT_RANGE_STUDS = 25
local CHASE_NOISE_HITS = 3 -- noise hits from one player...
local CHASE_NOISE_WINDOW_SECONDS = 5 -- ...within this window escalate to Chase
local CHASE_LOSE_SECONDS = 8 -- no sight + no noise -> back to Investigate
local INVESTIGATE_SWEEP_SECONDS = 10
local SWEEP_MOVE_INTERVAL_SECONDS = 2
local SWEEP_RADIUS_STUDS = 8
local REPATH_THROTTLE_SECONDS = 0.5
local BRAIN_TICK_SECONDS = 0.1
local WAYPOINT_REACHED_STUDS = 4
local TARGET_REACHED_STUDS = 6
local STUCK_SECONDS = 2.5
local STUCK_EPSILON_STUDS = 1
local POST_ATTACK_IGNORE_SECONDS = 6 -- don't instantly re-down the same player
local STALK_QUIET_SECONDS = 60 -- patrolling this long with no qualifying noise -> sweep the nearest participant
local FLYBY_SECONDS = 6
local FLYBY_LATERAL_STUDS = 20 -- closest approach to the player
local FLYBY_RUNWAY_STUDS = 22 -- walk-in / walk-out distance along the pass line

-- Floor-bounds fallback scoping (Change 6.5): a position is "on this floor"
-- when it sits inside the floor model's bounding box padded by this margin.
-- The 2000-stud slot pitch puts any cross-floor position thousands of studs
-- outside the padded box, so the assert can never misfire between sessions.
local FLOOR_BOUNDS_MARGIN_STUDS = 100

-- AgentRadius must clear RoomKit's 10-stud doorways: the navmesh erodes
-- openings by the radius on BOTH sides, so radius 4 leaves 2 studs and every
-- cross-room ComputeAsync returns NoPath (verified live: radius 4 reached 1/34
-- PatrolNodes, radius 2 reached 31/34). Only the 4-wide root part collides,
-- so radius 2 is physically honest too.
local AGENT_RADIUS = 2
local AGENT_HEIGHT = 12
local ROOT_GROUND_OFFSET = 7.5 -- root center height above the ground when spawning

local EYE_COLOR_IDLE = Color3.fromRGB(235, 190, 52) -- rarity gold (contract E)
local EYE_COLOR_CHASE = Color3.fromRGB(255, 40, 40)
local BODY_COLOR = Color3.fromRGB(178, 178, 178) -- fallback grey (variants recolor)

-- Colored Defect variants — ONE random variant spawns per shift. Balanced
-- trade-offs around the Red baseline (the original numbers); eyes still snap
-- red on Chase regardless of body color.
export type DefectVariant = {
	name: string,
	bodyColor: Color3,
	patrolSpeed: number,
	investigateSpeed: number,
	chaseSpeed: number,
	attackDamage: number,
	hearingMult: number,
}

local VARIANTS: { DefectVariant } = {
	-- Red: the baseline.
	{
		name = "Red",
		bodyColor = Color3.fromRGB(185, 70, 62),
		patrolSpeed = 8,
		investigateSpeed = 12,
		chaseSpeed = 17,
		attackDamage = 50,
		hearingMult = 1,
	},
	-- Yellow: faster everywhere, hits softer (3 hits to down).
	{
		name = "Yellow",
		bodyColor = Color3.fromRGB(225, 195, 80),
		patrolSpeed = 10,
		investigateSpeed = 14,
		chaseSpeed = 21,
		attackDamage = 34, -- 100 -> 66 -> 32 -> down (3 hits; 30 was a 4-hit)
		hearingMult = 1,
	},
	-- Green: slightly slower chase, but hears half again as far.
	{
		name = "Green",
		bodyColor = Color3.fromRGB(100, 180, 95),
		patrolSpeed = 8,
		investigateSpeed = 12,
		chaseSpeed = 15,
		attackDamage = 40,
		hearingMult = 1.5,
	},
	-- Violet: slow, half-deaf, and nearly a one-shot (65 + any chip = down).
	{
		name = "Violet",
		bodyColor = Color3.fromRGB(145, 85, 200),
		patrolSpeed = 6,
		investigateSpeed = 10,
		chaseSpeed = 13,
		attackDamage = 65,
		hearingMult = 0.85,
	},
}
local ACCENT_COLOR = Color3.fromRGB(235, 190, 52)

-- CollectionService tag on the live Defect model — the client RunHUD proximity
-- poll (heartbeat/vignette) discovers the Defect by this tag, so it works no
-- matter where the model is parented (it lives under the floor model).
local TAG_DEFECT = "Defect"

-- Greybox roar: built-in engine asset so it plays with zero uploads; swapped
-- for real audio in the art pass. Pitched down for the jump-scare beat (§1.4).
local ROAR_SOUND_ID = "rbxasset://sounds/uuhhh.mp3"
local ROAR_PLAYBACK_SPEED = 0.4
local ROAR_VOLUME = 1

--------------------------------------------------------------------------------
-- Types
--------------------------------------------------------------------------------

type DefectState = "Patrol" | "Investigate" | "Chase" | "Flyby"

type NoiseHit = {
	t: number, -- os.clock()
	pos: Vector3,
	userId: number?,
}

type Defect = {
	model: Model,
	humanoid: Humanoid,
	root: BasePart,
	eyes: { BasePart },
	roar: Sound,
	variant: DefectVariant,
	path: Path,
	active: boolean,
	state: DefectState,

	-- session scoping (R2 WP4.2): this AI's floor + cached bounding box
	floorRoot: Instance,
	boundsCFrame: CFrame?,
	boundsSize: Vector3?,

	-- per-session noise log + post-attack ignore set (never shared across AIs)
	noiseHits: { NoiseHit },
	attackIgnoreUntil: { [Player]: number },

	-- movement / path following
	waypoints: { PathWaypoint },
	waypointIndex: number,
	pathTarget: Vector3?,
	lastPathAt: number,
	lastPos: Vector3,
	lastMovedAt: number,

	-- patrol
	patrolNodes: { Vector3 },
	patrolTarget: Vector3?,

	-- investigate
	investigatePos: Vector3?,
	sweepUntil: number, -- 0 until the noise position is reached
	nextSweepMoveAt: number,
	sweepTarget: Vector3?,

	-- chase
	chaseTarget: Player?,
	lastContactAt: number,
	lastKnownPos: Vector3?,

	-- stalk pulse (quiet-crew pressure)
	lastHeardNoiseAt: number,

	-- stagger (CombatService weapon hits) — speed stays clamped until this
	staggeredUntil: number,

	-- flyby
	flybyUntil: number,
	flybyPoints: { Vector3 },
	flybyIndex: number,
}

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local DefectService = {}

-- One AI object per live shift session, keyed by its floor root (Change 6.5).
local ais: { [Instance]: Defect } = {}

-- ShiftService is built in parallel (Stage 1) — reach it lazily and safely.
local shiftServiceAttempted = false
local shiftService: any = nil

local function getShiftService(): any
	if not shiftServiceAttempted then
		shiftServiceAttempted = true
		local moduleScript = script.Parent and script.Parent:FindFirstChild("ShiftService")
		if moduleScript ~= nil and moduleScript:IsA("ModuleScript") then
			local ok, result = pcall(require, moduleScript)
			if ok and type(result) == "table" then
				shiftService = result
			else
				warn(`[DefectService] ShiftService require failed: {result}`)
			end
		end
	end
	return shiftService
end

--------------------------------------------------------------------------------
-- Greybox model
--------------------------------------------------------------------------------

local function makePart(
	parent: Model,
	name: string,
	shape: Enum.PartType?,
	size: Vector3,
	color: Color3,
	material: Enum.Material
): Part
	local part = Instance.new("Part")
	part.Name = name
	if shape ~= nil then
		part.Shape = shape
	end
	part.Size = size
	part.Color = color
	part.Material = material
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = true
	part.Massless = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

local function weldTo(root: BasePart, part: BasePart, offset: CFrame)
	part.CFrame = root.CFrame * offset
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = root
	weld.Part1 = part
	weld.Parent = part
end

-- Builds the ~12-stud blocky "misprint prototype" toy: asymmetric arms, tilted
-- head, mismatched neon eyes, one gold accent wedge. Pure greybox Parts.
local function buildDefectModel(
	spawnCFrame: CFrame,
	variant: DefectVariant
): (Model, Humanoid, BasePart, { BasePart }, Sound)
	local bodyColor = variant.bodyColor or BODY_COLOR
	local model = Instance.new("Model")
	model.Name = "Defect"
	model:SetAttribute("Variant", variant.name)
	CollectionService:AddTag(model, TAG_DEFECT)

	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(4, 6, 2)
	root.Transparency = 1
	root.CanCollide = true
	root.CanTouch = false
	root.CFrame = spawnCFrame
	root.Parent = model
	model.PrimaryPart = root

	local humanoid = Instance.new("Humanoid")
	humanoid.HipHeight = 4
	humanoid.WalkSpeed = variant.patrolSpeed
	humanoid.MaxHealth = 1e6
	humanoid.Health = 1e6
	humanoid.AutoRotate = true
	humanoid.BreakJointsOnDeath = false
	humanoid.Parent = model
	for _, state in
		{
			Enum.HumanoidStateType.Climbing,
			Enum.HumanoidStateType.Jumping,
			Enum.HumanoidStateType.FallingDown,
			Enum.HumanoidStateType.Ragdoll,
			Enum.HumanoidStateType.Seated,
			Enum.HumanoidStateType.PlatformStanding,
			Enum.HumanoidStateType.Swimming,
		}
	do
		humanoid:SetStateEnabled(state, false)
	end

	-- Body (front faces -Z of the root).
	local torso =
		makePart(model, "Torso", Enum.PartType.Block, Vector3.new(7, 6, 4.5), bodyColor, Enum.Material.Plastic)
	weldTo(root, torso, CFrame.new(0, 0, 0))

	-- The map is pitch black and the greybox body is unlit grey — without its
	-- own dim glow an approaching Defect is invisible until point-blank.
	local glow = Instance.new("PointLight")
	glow.Color = Color3.fromRGB(255, 60, 40)
	glow.Brightness = 1.2
	glow.Range = 16
	glow.Shadows = false
	glow.Parent = torso

	local head =
		makePart(model, "Head", Enum.PartType.Block, Vector3.new(5, 3.5, 4.5), bodyColor, Enum.Material.Plastic)
	weldTo(root, head, CFrame.new(0.4, 4.5, 0) * CFrame.Angles(0, 0, math.rad(8))) -- misprint tilt

	local accent = makePart(model, "Accent", nil, Vector3.new(2, 1.5, 2.5), ACCENT_COLOR, Enum.Material.SmoothPlastic)
	local accentMesh = Instance.new("SpecialMesh")
	accentMesh.MeshType = Enum.MeshType.Wedge
	accentMesh.Parent = accent
	weldTo(root, accent, CFrame.new(0.6, 6.8, 0) * CFrame.Angles(0, 0, math.rad(8)))

	local leftArm =
		makePart(model, "LeftArm", Enum.PartType.Block, Vector3.new(2, 7, 2), bodyColor, Enum.Material.Plastic)
	weldTo(root, leftArm, CFrame.new(-4.6, -1, 0) * CFrame.Angles(0, 0, math.rad(-6))) -- too-long arm, drags

	local rightArm =
		makePart(model, "RightArm", Enum.PartType.Block, Vector3.new(2, 4, 2), bodyColor, Enum.Material.Plastic)
	weldTo(root, rightArm, CFrame.new(4.6, 0.5, 0)) -- stubby arm

	local leftLeg =
		makePart(model, "LeftLeg", Enum.PartType.Block, Vector3.new(2.4, 4, 2.4), bodyColor, Enum.Material.Plastic)
	weldTo(root, leftLeg, CFrame.new(-1.6, -5, 0))

	local rightLeg =
		makePart(model, "RightLeg", Enum.PartType.Block, Vector3.new(2.4, 4, 2.4), bodyColor, Enum.Material.Plastic)
	weldTo(root, rightLeg, CFrame.new(1.6, -5, 0))

	-- Mismatched glowing eyes (misprint): one big, one small, both Neon.
	local eyeBig =
		makePart(model, "EyeBig", Enum.PartType.Ball, Vector3.new(1.5, 1.5, 1.5), EYE_COLOR_IDLE, Enum.Material.Neon)
	weldTo(root, eyeBig, CFrame.new(-0.9, 4.9, -2.3))

	local eyeSmall =
		makePart(model, "EyeSmall", Enum.PartType.Ball, Vector3.new(0.9, 0.9, 0.9), EYE_COLOR_IDLE, Enum.Material.Neon)
	weldTo(root, eyeSmall, CFrame.new(1.5, 4.5, -2.3))

	local roar = Instance.new("Sound")
	roar.Name = "Roar"
	roar.SoundId = ROAR_SOUND_ID
	roar.PlaybackSpeed = ROAR_PLAYBACK_SPEED
	roar.Volume = ROAR_VOLUME
	roar.RollOffMaxDistance = 150
	roar.Parent = head

	return model, humanoid, root, { eyeBig, eyeSmall }, roar
end

--------------------------------------------------------------------------------
-- Patrol node discovery
--------------------------------------------------------------------------------

local function collectPatrolNodes(floorModel: Instance): { Vector3 }
	local nodes: { Vector3 } = {}

	-- 1) CollectionService tag (preferred FloorGen convention), ancestor-walked:
	--    only nodes descending from THIS floor qualify — a global first-match
	--    would hand this AI another session's floor with 5 live (WP4.2).
	for _, tagged in CollectionService:GetTagged("PatrolNode") do
		if tagged:IsA("BasePart") and tagged:IsDescendantOf(floorModel) then
			table.insert(nodes, tagged.Position)
		end
	end
	if #nodes > 0 then
		return nodes
	end

	-- 2) A "PatrolNodes" folder of BaseParts anywhere in the floor model.
	local folder = floorModel:FindFirstChild("PatrolNodes", true)
	if folder ~= nil then
		for _, child in folder:GetChildren() do
			if child:IsA("BasePart") then
				table.insert(nodes, child.Position)
			end
		end
	end
	if #nodes > 0 then
		return nodes
	end

	-- 3) Any descendant BasePart named "PatrolNode".
	for _, descendant in floorModel:GetDescendants() do
		if descendant:IsA("BasePart") and descendant.Name == "PatrolNode" then
			table.insert(nodes, descendant.Position)
		end
	end
	if #nodes > 0 then
		return nodes
	end

	-- 4) Fallback: 3x3 grid inside the floor's bounding box so the Defect still
	--    patrols on a floor that hasn't shipped PatrolNodes yet.
	if floorModel:IsA("Model") then
		local boxCFrame, boxSize = floorModel:GetBoundingBox()
		local floorY = boxCFrame.Position.Y - boxSize.Y / 2
		for xi = -1, 1 do
			for zi = -1, 1 do
				local offset = Vector3.new(xi * boxSize.X * 0.3, 0, zi * boxSize.Z * 0.3)
				local pos = boxCFrame.Position + offset
				table.insert(nodes, Vector3.new(pos.X, floorY, pos.Z))
			end
		end
		warn("[DefectService] no PatrolNodes found in floor model — using bounding-box fallback grid")
	end

	return nodes
end

--------------------------------------------------------------------------------
-- Perception helpers
--------------------------------------------------------------------------------

local function getCharacterRoot(player: Player): BasePart?
	local character = player.Character
	if character == nil then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if root ~= nil and root:IsA("BasePart") then
		return root
	end
	return nil
end

-- Floor bounding box, computed once per AI at spawn (nil for non-Model
-- stand-ins in test places).
local function computeFloorBounds(floorModel: Instance): (CFrame?, Vector3?)
	if floorModel:IsA("Model") then
		local ok, boxCFrame, boxSize = pcall(floorModel.GetBoundingBox, floorModel)
		if ok then
			return boxCFrame, boxSize
		end
	end
	return nil, nil
end

-- True when the position sits inside the floor's padded bounding box (planar:
-- all slot origins share one Y). Unknown bounds fail OPEN so non-Model test
-- floors keep today's global behavior (Wave-4 house rule).
local function floorContains(boundsCFrame: CFrame?, boundsSize: Vector3?, position: Vector3): boolean
	if boundsCFrame == nil or boundsSize == nil then
		return true
	end
	local localPos = boundsCFrame:PointToObjectSpace(position)
	local half = boundsSize / 2
	return math.abs(localPos.X) <= half.X + FLOOR_BOUNDS_MARGIN_STUDS
		and math.abs(localPos.Z) <= half.Z + FLOOR_BOUNDS_MARGIN_STUDS
end

-- Change 6.5 target scoping: a player belongs to this AI's floor when the
-- ShiftService facade resolves their session's floor to THIS floor
-- (GetSessionOf/GetFloorRootFor — pcall + feature-detected). Facade absent
-- (test places, legacy builds): fall back to position within the floor's
-- bounds — the 2000-stud pitch lands cross-floor positions far outside the
-- padded box, so the assert holds even without the facade.
local function isPlayerOnFloor(
	floorRoot: Instance,
	boundsCFrame: CFrame?,
	boundsSize: Vector3?,
	player: Player
): boolean
	local targetRoot = getCharacterRoot(player)
	if targetRoot == nil then
		return false
	end
	local shift = getShiftService()
	if shift ~= nil and type(shift.GetFloorRootFor) == "function" then
		local ok, sessionFloor = pcall(shift.GetFloorRootFor, player)
		if ok then
			return sessionFloor == floorRoot
		end
	end
	return floorContains(boundsCFrame, boundsSize, targetRoot.Position)
end

-- Live participants of THIS floor's session only. Hub bystanders idle 3000+
-- studs away and players on OTHER concurrent floors MUST NOT steer
-- spawn/patrol/target decisions (with all players in the pool, the patrol
-- bias chases the wrong crowd and the far-spawn metric is polluted). Falls
-- back to everyone with a character inside the floor bounds when ShiftService
-- is absent (test places).
local function getParticipants(floorRoot: Instance, boundsCFrame: CFrame?, boundsSize: Vector3?): { Player }
	local shift = getShiftService()
	local hasCheck = shift ~= nil and type(shift.IsParticipant) == "function"
	local result: { Player } = {}
	for _, player in Players:GetPlayers() do
		if getCharacterRoot(player) ~= nil and isPlayerOnFloor(floorRoot, boundsCFrame, boundsSize, player) then
			local include = true
			if hasCheck then
				local ok, isIn = pcall(shift.IsParticipant, player)
				include = ok and isIn == true
				if include and type(shift.HasExtracted) == "function" then
					local okOut, isOut = pcall(shift.HasExtracted, player)
					if okOut and isOut == true then
						include = false
					end
				end
			end
			if include then
				table.insert(result, player)
			end
		end
	end
	return result
end

-- Resolves the AI responsible for this player's floor: facade route first,
-- then bounds containment, then the only live AI (legacy single-session).
local function getAiForPlayer(player: Player): Defect?
	local shift = getShiftService()
	if shift ~= nil and type(shift.GetFloorRootFor) == "function" then
		local ok, sessionFloor = pcall(shift.GetFloorRootFor, player)
		if ok and typeof(sessionFloor) == "Instance" then
			return ais[sessionFloor]
		end
	end
	local targetRoot = getCharacterRoot(player)
	local single: Defect? = nil
	local liveCount = 0
	for _, ai in ais do
		if ai.active and ai.model.Parent ~= nil then
			liveCount += 1
			single = ai
			if
				targetRoot ~= nil
				and ai.boundsCFrame ~= nil -- multi-AI matching needs REAL bounds (no fail-open)
				and floorContains(ai.boundsCFrame, ai.boundsSize, targetRoot.Position)
			then
				return ai
			end
		end
	end
	return if liveCount == 1 then single else nil
end

-- True when the segment from the Defect's eyes to the player's root is
-- unobstructed (hits the character first, or nothing at all).
local function canSee(self: Defect, player: Player): boolean
	local targetRoot = getCharacterRoot(player)
	if targetRoot == nil then
		return false
	end

	local origin = self.root.Position + Vector3.new(0, 4, 0) -- eye height
	local delta = targetRoot.Position - origin
	if delta.Magnitude > SIGHT_RANGE_STUDS then
		return false
	end

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { self.model }
	local result = workspace:Raycast(origin, delta, params)
	if result == nil then
		return true -- nothing between the eyes and the target root
	end
	local character = player.Character
	return character ~= nil and result.Instance:IsDescendantOf(character)
end

-- Skip players this Defect just downed (and downed players, when ShiftService
-- exposes IsDowned) so it doesn't camp a body. Per-AI ignore set: a hit on
-- floor A never shields the same player from floor B's AI (irrelevant in
-- play — a player occupies one session — but keeps the state honest).
local function isValidChaseTarget(self: Defect, player: Player, now: number): boolean
	if player.Parent == nil or getCharacterRoot(player) == nil then
		return false
	end
	local ignoreUntil = self.attackIgnoreUntil[player]
	if ignoreUntil ~= nil and now < ignoreUntil then
		return false
	end
	local shift = getShiftService()
	if shift ~= nil and type(shift.IsDowned) == "function" then
		local ok, downed = pcall(shift.IsDowned, player)
		if ok and downed == true then
			return false
		end
	end
	return true
end

local function pruneNoiseHits(self: Defect, now: number)
	local noiseHits = self.noiseHits
	local cutoff = now - CHASE_NOISE_WINDOW_SECONDS
	local write = 1
	for read = 1, #noiseHits do
		local hit = noiseHits[read]
		if hit.t >= cutoff then
			noiseHits[write] = hit
			write += 1
		end
	end
	for index = #noiseHits, write, -1 do
		noiseHits[index] = nil
	end
end

local function countRecentHitsFrom(self: Defect, userId: number, now: number): number
	local count = 0
	local cutoff = now - CHASE_NOISE_WINDOW_SECONDS
	for _, hit in self.noiseHits do
		if hit.userId == userId and hit.t >= cutoff then
			count += 1
		end
	end
	return count
end

--------------------------------------------------------------------------------
-- Movement: throttled PathfindingService + Humanoid:MoveTo
--------------------------------------------------------------------------------

local rng = Random.new()

-- Most patrol legs drift toward a participant (greybox floors are 200+ studs
-- across; a pure random walk can starve a whole shift of encounters — the
-- playtest symptom was "I never see the monster"). The rest stay uniform so
-- the Defect remains unpredictable.
local PATROL_PLAYER_BIAS = 0.7

local function pickPatrolNode(self: Defect): Vector3
	local nodes = self.patrolNodes
	if rng:NextNumber() < PATROL_PLAYER_BIAS then
		local players = getParticipants(self.floorRoot, self.boundsCFrame, self.boundsSize)
		if #players > 0 then
			local targetRoot = getCharacterRoot(players[rng:NextInteger(1, #players)])
			if targetRoot ~= nil then
				local best: Vector3? = nil
				local bestDist = math.huge
				for _, node in nodes do
					local dist = (node - targetRoot.Position).Magnitude
					if dist < bestDist then
						best = node
						bestDist = dist
					end
				end
				if best ~= nil then
					return best
				end
			end
		end
	end
	return nodes[rng:NextInteger(1, #nodes)]
end

local function resetPathing(self: Defect)
	self.waypoints = {}
	self.waypointIndex = 1
	self.pathTarget = nil
	self.lastPathAt = 0
end

-- Walks toward targetPos, recomputing the path at most every 0.5s and only
-- when the target moved or the current waypoint list is exhausted. Falls back
-- to a direct MoveTo when pathfinding fails (greybox floors are mostly open).
local function moveTowards(self: Defect, targetPos: Vector3, now: number)
	local needRepath = self.pathTarget == nil
		or (self.pathTarget :: Vector3 - targetPos).Magnitude > 2
		or self.waypointIndex > #self.waypoints

	if needRepath and now - self.lastPathAt >= REPATH_THROTTLE_SECONDS then
		self.lastPathAt = now
		self.pathTarget = targetPos
		self.waypoints = {}
		self.waypointIndex = 1

		local ok = pcall(function()
			self.path:ComputeAsync(self.root.Position, targetPos)
		end)
		if ok and self.path.Status == Enum.PathStatus.Success then
			self.waypoints = self.path:GetWaypoints()
			self.waypointIndex = 1
		end
	end

	-- Advance past reached waypoints (planar distance).
	local rootPos = self.root.Position
	while self.waypointIndex <= #self.waypoints do
		local waypointPos = self.waypoints[self.waypointIndex].Position
		local planar = Vector3.new(waypointPos.X - rootPos.X, 0, waypointPos.Z - rootPos.Z)
		if planar.Magnitude <= WAYPOINT_REACHED_STUDS then
			self.waypointIndex += 1
		else
			break
		end
	end

	if self.waypointIndex <= #self.waypoints then
		self.humanoid:MoveTo(self.waypoints[self.waypointIndex].Position)
	else
		self.humanoid:MoveTo(targetPos) -- no/failed/finished path: walk straight at it
	end
end

local function reachedTarget(self: Defect, targetPos: Vector3): boolean
	local rootPos = self.root.Position
	local planar = Vector3.new(targetPos.X - rootPos.X, 0, targetPos.Z - rootPos.Z)
	return planar.Magnitude <= TARGET_REACHED_STUDS
end

-- True when the Defect has been trying to move but hasn't covered ground.
local function updateStuck(self: Defect, now: number): boolean
	if (self.root.Position - self.lastPos).Magnitude > STUCK_EPSILON_STUDS then
		self.lastPos = self.root.Position
		self.lastMovedAt = now
		return false
	end
	if now - self.lastMovedAt > STUCK_SECONDS then
		self.lastMovedAt = now -- give the recovery a full window before re-triggering
		return true
	end
	return false
end

--------------------------------------------------------------------------------
-- FSM transitions
--------------------------------------------------------------------------------

local function setEyes(self: Defect, color: Color3)
	for _, eye in self.eyes do
		eye.Color = color
	end
end

local function playRoar(self: Defect)
	pcall(function()
		self.roar:Play()
	end)
end

-- Centralized speed write: every state entry routes through here so an FSM
-- transition can never cancel an active stagger — the clamp holds until
-- staggeredUntil, then the ApplyStagger task.delay restores the state speed.
local function applySpeed(self: Defect)
	local speed = if self.state == "Chase"
		then self.variant.chaseSpeed
		elseif self.state == "Patrol" then self.variant.patrolSpeed
		else self.variant.investigateSpeed -- Investigate and Flyby
	if os.clock() < self.staggeredUntil then
		speed = math.min(speed, 2)
	end
	self.humanoid.WalkSpeed = speed
end

local function enterPatrol(self: Defect)
	self.state = "Patrol"
	self.chaseTarget = nil
	self.investigatePos = nil
	self.patrolTarget = nil
	applySpeed(self)
	setEyes(self, EYE_COLOR_IDLE)
	resetPathing(self)
end

local function enterInvestigate(self: Defect, pos: Vector3)
	self.state = "Investigate"
	self.chaseTarget = nil
	self.investigatePos = pos
	self.sweepUntil = 0 -- set once the position is reached
	self.nextSweepMoveAt = 0
	self.sweepTarget = nil
	applySpeed(self)
	setEyes(self, EYE_COLOR_IDLE)
	resetPathing(self)
end

-- The clip-able jump-scare beat (§1.4): roar + eyes snap red.
local function enterChase(self: Defect, target: Player, now: number)
	self.state = "Chase"
	self.chaseTarget = target
	self.lastContactAt = now
	local targetRoot = getCharacterRoot(target)
	self.lastKnownPos = if targetRoot ~= nil then targetRoot.Position else self.root.Position
	applySpeed(self)
	setEyes(self, EYE_COLOR_CHASE)
	playRoar(self)
	resetPathing(self)
end

local function isFlybyActive(self: Defect, now: number): boolean
	return self.state == "Flyby" and now < self.flybyUntil
end

--------------------------------------------------------------------------------
-- Per-state ticks
--------------------------------------------------------------------------------

-- Sight check shared by Patrol and Investigate: nearest visible valid player
-- ON THIS AI'S FLOOR — never a target from a concurrent session (Change 6.5).
local function findVisibleTarget(self: Defect, now: number): Player?
	local best: Player? = nil
	local bestDist = SIGHT_RANGE_STUDS + 1
	for _, player in Players:GetPlayers() do
		if
			isValidChaseTarget(self, player, now)
			and isPlayerOnFloor(self.floorRoot, self.boundsCFrame, self.boundsSize, player)
		then
			local targetRoot = getCharacterRoot(player)
			if targetRoot ~= nil then
				local dist = (targetRoot.Position - self.root.Position).Magnitude
				if dist <= SIGHT_RANGE_STUDS and dist < bestDist and canSee(self, player) then
					best = player
					bestDist = dist
				end
			end
		end
	end
	return best
end

local function tickPatrol(self: Defect, now: number)
	local seen = findVisibleTarget(self, now)
	if seen ~= nil then
		enterChase(self, seen, now)
		return
	end

	-- Stalk pulse: a careful, quiet crew still gets pressured — after 60s of
	-- silence the Defect sweeps the nearest participant's current position.
	if now - self.lastHeardNoiseAt >= STALK_QUIET_SECONDS then
		self.lastHeardNoiseAt = now -- restart the quiet window either way
		local nearestPos: Vector3? = nil
		local nearestDist = math.huge
		for _, player in getParticipants(self.floorRoot, self.boundsCFrame, self.boundsSize) do
			if isValidChaseTarget(self, player, now) then
				local targetRoot = getCharacterRoot(player)
				if targetRoot ~= nil then
					local dist = (targetRoot.Position - self.root.Position).Magnitude
					if dist < nearestDist then
						nearestDist = dist
						nearestPos = targetRoot.Position
					end
				end
			end
		end
		if nearestPos ~= nil then
			enterInvestigate(self, nearestPos)
			return
		end
	end

	if #self.patrolNodes == 0 then
		return -- nothing to walk between; perception still runs
	end

	if self.patrolTarget == nil or reachedTarget(self, self.patrolTarget :: Vector3) then
		self.patrolTarget = pickPatrolNode(self)
		resetPathing(self)
	end
	moveTowards(self, self.patrolTarget :: Vector3, now)

	if updateStuck(self, now) then
		self.patrolTarget = pickPatrolNode(self)
		resetPathing(self)
	end
end

local function tickInvestigate(self: Defect, now: number)
	local seen = findVisibleTarget(self, now)
	if seen ~= nil then
		enterChase(self, seen, now)
		return
	end

	local pos = self.investigatePos
	if pos == nil then
		enterPatrol(self)
		return
	end

	if self.sweepUntil == 0 then
		-- Phase 1: converge on the noise position. A stuck Defect (noise heard
		-- through a wall) starts sweeping from wherever it stands.
		moveTowards(self, pos, now)
		if reachedTarget(self, pos) or updateStuck(self, now) then
			self.sweepUntil = now + INVESTIGATE_SWEEP_SECONDS
			self.nextSweepMoveAt = now
		end
	else
		-- Phase 2: 10s sweep around the position.
		if now >= self.sweepUntil then
			enterPatrol(self)
			return
		end
		if now >= self.nextSweepMoveAt then
			self.nextSweepMoveAt = now + SWEEP_MOVE_INTERVAL_SECONDS
			local angle = rng:NextNumber(0, math.pi * 2)
			local radius = rng:NextNumber(SWEEP_RADIUS_STUDS * 0.4, SWEEP_RADIUS_STUDS)
			self.sweepTarget = pos + Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
			resetPathing(self)
		end
		if self.sweepTarget ~= nil then
			moveTowards(self, self.sweepTarget :: Vector3, now)
		end
	end
end

local function tickChase(self: Defect, now: number)
	local target = self.chaseTarget
	if target == nil or target.Parent == nil then
		enterPatrol(self)
		return
	end

	local targetRoot = getCharacterRoot(target)
	if targetRoot == nil then
		-- Character despawned mid-chase: sweep the last known position.
		enterInvestigate(self, self.lastKnownPos or self.root.Position)
		return
	end

	-- Sight refreshes contact and the last known position.
	if canSee(self, target) then
		self.lastContactAt = now
		self.lastKnownPos = targetRoot.Position
	end

	-- Lost it: 8s with no sight and no noise from the target.
	if now - self.lastContactAt > CHASE_LOSE_SECONDS then
		enterInvestigate(self, self.lastKnownPos or targetRoot.Position)
		return
	end

	-- Attack: <=4 studs PLANAR. Planar because the 12-stud Defect's root rides
	-- ~5.5 studs above a player root — a 3D magnitude can never reach 4, so it
	-- would camp the target forever. Each hit deals DEFECT_ATTACK_DAMAGE
	-- (two-hit kill, §G): the player only goes DOWN when the hit exhausts
	-- their health; otherwise they take the hit, the Defect breaks off
	-- (post-attack ignore), and the chase resets — run while you can.
	local offset = targetRoot.Position - self.root.Position
	local dist = Vector3.new(offset.X, 0, offset.Z).Magnitude
	if dist <= ATTACK_RANGE_STUDS then
		self.attackIgnoreUntil[target] = now + POST_ATTACK_IGNORE_SECONDS

		local humanoid = target.Character and target.Character:FindFirstChildOfClass("Humanoid")
		local lethal = humanoid == nil or humanoid.Health - self.variant.attackDamage <= 1
		if humanoid ~= nil and not lethal then
			humanoid.Health -= self.variant.attackDamage
			playRoar(self)
		else
			if humanoid ~= nil then
				humanoid.Health = 1 -- DownPlayer owns the downed state; never let the hit kill outright
			end
			local shift = getShiftService()
			if shift ~= nil and type(shift.DownPlayer) == "function" then
				local ok, err = pcall(shift.DownPlayer, target)
				if not ok then
					warn(`[DefectService] ShiftService.DownPlayer failed: {err}`)
				end
			else
				warn("[DefectService] ShiftService.DownPlayer unavailable — attack landed with no effect")
			end
		end
		enterInvestigate(self, targetRoot.Position)
		return
	end

	moveTowards(self, self.lastKnownPos or targetRoot.Position, now)

	if updateStuck(self, now) then
		resetPathing(self) -- force a fresh path next tick
	end
end

local function tickFlyby(self: Defect, now: number)
	if now >= self.flybyUntil or self.flybyIndex > #self.flybyPoints then
		enterPatrol(self)
		return
	end

	local point = self.flybyPoints[self.flybyIndex]
	moveTowards(self, point, now)
	-- Advance on arrival, and on stuck too — never stall the scripted beat.
	if reachedTarget(self, point) or updateStuck(self, now) then
		self.flybyIndex += 1
	end
end

--------------------------------------------------------------------------------
-- Brain loop
--------------------------------------------------------------------------------

local function runBrain(self: Defect)
	while self.active and self.model.Parent ~= nil do
		local now = os.clock()
		pruneNoiseHits(self, now)

		if self.state == "Flyby" then
			tickFlyby(self, now)
		elseif self.state == "Chase" then
			tickChase(self, now)
		elseif self.state == "Investigate" then
			tickInvestigate(self, now)
		else
			tickPatrol(self, now)
		end

		task.wait(BRAIN_TICK_SECONDS)
	end
end

--------------------------------------------------------------------------------
-- Noise intake (NoiseService subscription)
--------------------------------------------------------------------------------

-- Contract G: an AI reacts when
--   loudness * max(0, 1 - distance / HEARING_RANGE_MAX) > DEFECT_HEARING_THRESHOLD
-- Change 6.5: each AI hears only ITS floor — the WP4.1 floorRoot passthrough
-- is authoritative when present; otherwise the noise position must sit inside
-- this floor's bounds (cross-floor noise lands 2000+ studs away, far beyond
-- hearing range AND outside the padded box — asserted anyway).
local function handleNoise(self: Defect, event: NoiseService.NoiseEvent, eventFloor: Instance?)
	if not self.active or self.model.Parent == nil then
		return
	end
	if eventFloor ~= nil then
		if eventFloor ~= self.floorRoot then
			return
		end
	elseif not floorContains(self.boundsCFrame, self.boundsSize, event.pos) then
		return
	end

	local now = os.clock()
	if isFlybyActive(self, now) then
		return -- scripted flyby ignores all noise for its duration
	end

	local distance = (event.pos - self.root.Position).Magnitude
	local heard = event.loudness
		* math.max(0, 1 - distance / (GameConstants.HEARING_RANGE_MAX * self.variant.hearingMult))
	if heard <= GameConstants.DEFECT_HEARING_THRESHOLD then
		return
	end
	self.lastHeardNoiseAt = now -- qualifying noise resets the stalk-pulse quiet window

	local source = event.source
	local sourceValid = source ~= nil and isValidChaseTarget(self, source :: Player, now)

	table.insert(self.noiseHits, {
		t = now,
		pos = event.pos,
		userId = if sourceValid then (source :: Player).UserId else nil,
	})

	if self.state == "Chase" then
		-- Noise from the chase target refreshes contact.
		local target = self.chaseTarget
		if target ~= nil and source == target then
			self.lastContactAt = now
			self.lastKnownPos = event.pos
		end
		return
	end

	-- 3 hits from the same player within 5s escalate straight to Chase.
	if sourceValid and countRecentHitsFrom(self, (source :: Player).UserId, now) >= CHASE_NOISE_HITS then
		enterChase(self, source :: Player, now)
		return
	end

	-- Patrol/Investigate: converge on the (latest) noise.
	enterInvestigate(self, event.pos)
end

-- NoiseService fanout: ONE subscription dispatches to every live per-session
-- AI; handleNoise applies the floor filter per AI.
local function onNoise(event: NoiseService.NoiseEvent)
	local passthrough = (event :: any).floorRoot -- WP4.1 additive field (optional)
	local eventFloor: Instance? = if typeof(passthrough) == "Instance" then passthrough else nil
	for _, ai in ais do
		handleNoise(ai, event, eventFloor)
	end
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- Tears down one floor's AI. Idempotent; the brain loop exits on active=false.
local function teardownAi(floorRoot: Instance)
	local self = ais[floorRoot]
	if self == nil then
		return
	end
	ais[floorRoot] = nil
	self.active = false
	if self.model.Parent ~= nil then
		self.model:Destroy()
	end
	table.clear(self.noiseHits)
	table.clear(self.attackIgnoreUntil)
end

-- Called by ShiftService/ShiftSession when a shift goes Active. Builds the
-- per-session AI for THAT floor (replacing a previous AI on the SAME floor
-- only — concurrent sessions are untouched) and spawns its Defect at the
-- PatrolNode farthest from the session's own player characters.
function DefectService.OnShiftActive(floorModel: Instance)
	if typeof(floorModel) ~= "Instance" then
		warn("[DefectService] OnShiftActive: floorModel must be an Instance")
		return
	end

	DefectService.OnShiftEnded(floorModel) -- one Defect per floor

	local nodes = collectPatrolNodes(floorModel)
	if #nodes == 0 then
		warn("[DefectService] OnShiftActive: no spawn positions available — Defect not spawned")
		return
	end

	local boundsCFrame, boundsSize = computeFloorBounds(floorModel)

	-- Far spawn: maximize the minimum distance to any character of THIS
	-- session's participants.
	local characterPositions: { Vector3 } = {}
	for _, player in getParticipants(floorModel, boundsCFrame, boundsSize) do
		local characterRoot = getCharacterRoot(player)
		if characterRoot ~= nil then
			table.insert(characterPositions, characterRoot.Position)
		end
	end

	local spawnNode = nodes[rng:NextInteger(1, #nodes)]
	if #characterPositions > 0 then
		local bestScore = -1
		for _, node in nodes do
			local minDist = math.huge
			for _, charPos in characterPositions do
				minDist = math.min(minDist, (node - charPos).Magnitude)
			end
			if minDist > bestScore then
				bestScore = minDist
				spawnNode = node
			end
		end
	end

	local spawnCFrame = CFrame.new(spawnNode + Vector3.new(0, ROOT_GROUND_OFFSET, 0))
	-- One random variant per shift (the shift's whole personality).
	local variant = VARIANTS[rng:NextInteger(1, #VARIANTS)]
	local model, humanoid, root, eyes, roar = buildDefectModel(spawnCFrame, variant)

	local self: Defect = {
		model = model,
		humanoid = humanoid,
		root = root,
		eyes = eyes,
		roar = roar,
		variant = variant,
		floorRoot = floorModel,
		boundsCFrame = boundsCFrame,
		boundsSize = boundsSize,
		noiseHits = {},
		attackIgnoreUntil = {},
		path = PathfindingService:CreatePath({
			AgentRadius = AGENT_RADIUS,
			AgentHeight = AGENT_HEIGHT,
			AgentCanJump = false,
		}),
		active = true,
		state = "Patrol",
		waypoints = {},
		waypointIndex = 1,
		pathTarget = nil,
		lastPathAt = 0,
		lastPos = root.Position,
		lastMovedAt = os.clock(),
		patrolNodes = nodes,
		patrolTarget = nil,
		investigatePos = nil,
		sweepUntil = 0,
		nextSweepMoveAt = 0,
		sweepTarget = nil,
		chaseTarget = nil,
		lastContactAt = 0,
		lastKnownPos = nil,
		lastHeardNoiseAt = os.clock(),
		staggeredUntil = 0,
		flybyUntil = 0,
		flybyPoints = {},
		flybyIndex = 1,
	}
	ais[floorModel] = self

	-- Parent under the floor so floor teardown can never strand a Defect;
	-- server keeps network ownership for authoritative movement.
	model.Parent = floorModel
	pcall(function()
		root:SetNetworkOwner(nil)
	end)

	enterPatrol(self)
	task.spawn(runBrain, self)
end

-- Contract: CombatService weapon hits. Briefly slows a live Defect so a
-- cornered player can fight their way out; the speed restores to whatever the
-- current FSM state's variant speed is when the stagger expires.
-- R2 WP4.2 (additive): optional target — the Defect model, any of its parts,
-- or its floor root — scopes the stagger to one session's AI. Legacy
-- no-target calls (CombatService passes only seconds) stagger EVERY live
-- Defect: a bounded cross-floor leak that disappears once CombatService's own
-- global first-match Defect targeting is scoped (flagged to the WP6.4 audit).
function DefectService.ApplyStagger(seconds: number?, target: Instance?): boolean
	local duration = math.clamp(if type(seconds) == "number" then seconds else 2, 0.5, 6)
	local staggered = false
	for floorRoot, self in ais do
		if self.active and self.model.Parent ~= nil then
			local matches = target == nil
				or target == floorRoot
				or target == self.model
				or target:IsDescendantOf(self.model)
			if matches then
				local now = os.clock()
				self.staggeredUntil = math.max(self.staggeredUntil, now + duration)
				applySpeed(self)
				playRoar(self)
				task.delay(self.staggeredUntil - now, function()
					if ais[self.floorRoot] ~= self or not self.active or os.clock() < self.staggeredUntil then
						return -- despawned, or a later stagger extended the deadline (its own delay restores)
					end
					applySpeed(self)
				end)
				staggered = true
			end
		end
	end
	return staggered
end

-- Called by ShiftService/ShiftSession when a shift ends (Complete or aborted).
-- R2 WP4.2: the optional floorRoot tears down THAT floor's AI only — sibling
-- sessions keep hunting. nil keeps the legacy clear-everything semantics
-- (test places, older callers).
function DefectService.OnShiftEnded(floorRoot: Instance?)
	if floorRoot ~= nil then
		teardownAi(floorRoot)
		return
	end
	local roots: { Instance } = {}
	for root in ais do
		table.insert(roots, root)
	end
	for _, root in roots do
		teardownAi(root)
	end
end

-- Legacy lifecycle aliases (kept per WP4.2; the ShiftSession caller
-- feature-detects OnShiftActive/OnShiftEnded first and only falls back here).
function DefectService.OnShiftStart(floorModel: Instance, _seed: number?)
	DefectService.OnShiftActive(floorModel)
end

function DefectService.OnShiftEnd(floorRoot: Instance?)
	DefectService.OnShiftEnded(floorRoot)
end

-- R9 intro floor: a full Defect VISUAL (torso/head/dragging arms/mismatched
-- glowing eyes/red glow) + a Humanoid, with NO AI wiring and WITHOUT the Defect
-- tag (so the real per-shift AI never adopts it). The intro runner parents this
-- and drives a slow, NON-LETHAL chase itself. Returns the model + its Humanoid.
function DefectService.BuildCosmeticModel(spawnCFrame: CFrame): (Model, Humanoid)
	local variant = VARIANTS[1]
	local model, humanoid = buildDefectModel(spawnCFrame, variant)
	CollectionService:RemoveTag(model, TAG_DEFECT)
	model.Name = "IntroChaser"
	return model, humanoid
end

-- Contract I: scripted NON-AGGRO onboarding pass (OnboardingBeat "DefectFlyby",
-- SOP §3.2). The Defect crosses the player's view at a closest approach of
-- ~20 studs, roars, and ignores all noise for the 6s duration. It can never
-- down anyone while flying by. R2 WP4.2: routes to the AI on the player's own
-- floor (facade-resolved). Returns false when that floor has no live Defect
-- or the player has no character.
function DefectService.PlayFlyby(nearPlayer: Player): boolean
	if typeof(nearPlayer) ~= "Instance" or not nearPlayer:IsA("Player") then
		warn("[DefectService] PlayFlyby: nearPlayer must be a Player")
		return false
	end
	local self = getAiForPlayer(nearPlayer)
	if self == nil or not self.active or self.model.Parent == nil then
		warn("[DefectService] PlayFlyby: no active Defect on this player's floor")
		return false
	end
	local targetRoot = getCharacterRoot(nearPlayer)
	if targetRoot == nil then
		warn(`[DefectService] PlayFlyby: {nearPlayer.Name} has no character`)
		return false
	end

	local now = os.clock()
	local playerCFrame = targetRoot.CFrame
	local look = playerCFrame.LookVector
	local lookFlat = Vector3.new(look.X, 0, look.Z)
	if lookFlat.Magnitude < 0.05 then
		lookFlat = Vector3.zAxis
	else
		lookFlat = lookFlat.Unit
	end
	local lateral = lookFlat:Cross(Vector3.yAxis) -- player's right, horizontal

	-- Closest-approach point ~20 studs in front-right of the player; the Defect
	-- walks a line through it across the player's view (the clip-able beat).
	local approach = targetRoot.Position + lookFlat * FLYBY_LATERAL_STUDS
	local entry = approach + lateral * FLYBY_RUNWAY_STUDS
	local exit = approach - lateral * FLYBY_RUNWAY_STUDS

	self.state = "Flyby"
	self.chaseTarget = nil
	self.investigatePos = nil
	self.flybyUntil = now + FLYBY_SECONDS
	self.flybyPoints = { entry, approach, exit }
	self.flybyIndex = 1
	applySpeed(self)
	setEyes(self, EYE_COLOR_IDLE)
	resetPathing(self)
	playRoar(self)
	return true
end

--------------------------------------------------------------------------------
-- Loader lifecycle
--------------------------------------------------------------------------------

function DefectService:Init()
	NoiseService.OnNoise(onNoise)

	Players.PlayerRemoving:Connect(function(player)
		for _, ai in ais do
			ai.attackIgnoreUntil[player] = nil
			if ai.chaseTarget == player then
				ai.chaseTarget = nil
			end
		end
	end)
end

return DefectService
