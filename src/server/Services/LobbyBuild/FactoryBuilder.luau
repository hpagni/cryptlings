--!strict
-- CRYPTLINGS: NIGHT SHIFT — FactoryBuilder: the Factory end of the street
-- lobby (LOBBY_SOP §1.3; R2 WP2.2 — Addendum 1 Changes 4 & 8 removals).
--
-- Pure construction: no signals, no player logic, no Init/Start. Invoked only
-- by the HubService orchestrator as Build(parent, origin); all coordinates are
-- origin-relative (origin = GameConstants.HUB_ORIGIN). Street axis = X with
-- the Factory capping the EAST end (matches the old hub orientation so
-- ShiftService's >400-stud "on shift" heuristic keeps working).
--
-- Layout derivation (shared LobbyConfig math — StreetBuilder derives the same
-- envelope): the 10-lot strip spans LOTS_PER_SIDE * (LOT_FRONTAGE + LOT_GAP)
-- = 530 studs centered on the origin, so the street's east mouth is at
-- x = +265; the Factory plaza runs 100 studs deeper and the façade west face
-- sits at x = +365. The façade spans the full enclosure width (corridor +
-- a lot depth each side) — the building IS the east boundary; mountains cap
-- only the two long sides (SOP §1.5).
--
-- Façade plate (west face, z-negative = south):
--   * "Factory" Neon block letters (amber-red) centered at y 28, washed by
--     the 2 marquee SpotLights — the 2 feature lights SOP §2.6 allots here.
--   * Hazard shift door at z 0 (decorative — the queue pad is the real gate).
--   * North, low: the BrainrotWall slab region (WallBuilder mounts the 48x14
--     slab at the returned wallSlabCFrame, facing the queue pad).
--   * North, high: "TOP COLLECTORS" leaderboard (LEADERBOARD_MAX_ROWS rows).
--   * Above the door (y 14-24, z +/-10): free plate QueuePadBuilder may use
--     for its facade board (facadeCFrame anchors it).
--   * South: "ON SHIFT NOW" status sign under the CountdownWall slab.
--
-- Preserved legacy fixture contracts (consumers verified this session):
--   * CountdownWall — slab Part literally NAMED "CountdownWall" AND tagged
--     "CountdownWall" (CountdownUI adorns its SurfaceGui to it, Face=Front;
--     the part is yawed so Front faces the plaza).
--   * Status sign / leaderboard — HubService's Start() loops re-use the
--     returned statusLabel / leaderboardRows verbatim.
--   * First-join SpawnLocation (Neutral, Duration 0) on the plaza beside the
--     queue pad position, facing the Factory (GetSpawn/GetSpawnPosition).
--
-- Removed per Addendum 1 (R2): the physical locker bank (Change 4 — the
-- locker is UI-tab-only; no Locker{i} parts or bank tags exist in the world)
-- and the plaza water-feature centerpiece with its emitters + PointLight
-- (Change 8 — the plaza ground reverts to plain paving; the freed feature
-- light slot is reassigned to PlazaBuilder's swap-meet stall light).

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConstants = require(Shared:WaitForChild("Config"):WaitForChild("GameConstants"))
local LobbyConfig = require(Shared:WaitForChild("Config"):WaitForChild("LobbyConfig"))
local PartKit = require(script.Parent:WaitForChild("PartKit"))

local FactoryBuilder = {}

--------------------------------------------------------------------------------
-- Contracts & derived layout
--------------------------------------------------------------------------------

local TAG_COUNTDOWN_WALL = "CountdownWall"

local LEADERBOARD_ROWS = GameConstants.LEADERBOARD_MAX_ROWS

-- Shared envelope math (see header): lot strip is centered on the origin.
local LOT_STRIP_HALF = LobbyConfig.LOTS_PER_SIDE * (LobbyConfig.LOT_FRONTAGE_STUDS + LobbyConfig.LOT_GAP_STUDS) / 2
local FRONT_X = LOT_STRIP_HALF + LobbyConfig.FACTORY_PLAZA_DEPTH_STUDS -- façade west face plane (= +365)
local FACADE_WIDTH = LobbyConfig.CORRIDOR_WIDTH_STUDS + 2 * LobbyConfig.LOT_DEPTH_STUDS + 4 -- full east boundary
local WALL_THICKNESS = 2
local BODY_DEPTH = 60
local BODY_HEIGHT = 38

-- Marquee letters: center height chosen so the string sits clear of the door
-- (top y 14), the roster-board plate (y 14-24) and the leaderboard (y >= 18,
-- z >= +28 — "Factory" spans only +/-21.6 z at letter height 8).
local LETTERS_Y = 28

-- BrainrotWall slab region (WallBuilder builds the slab at this CFrame):
-- 48 x 14 on the north façade, low (z +10..+58, y 2..16), facing the pad.
local WALL_SLAB_Z = 10 + LobbyConfig.BRAINROT_WALL.WIDTH_STUDS / 2
local WALL_SLAB_Y = 2 + LobbyConfig.BRAINROT_WALL.HEIGHT_STUDS / 2

-- Queue pad lands in front of the door (QueuePadBuilder, same derivation);
-- the spawn pad sits beside that spot, south, facing the Factory.
local SPAWN_POSITION_X = FRONT_X - 27
local SPAWN_POSITION_Z = -24

-- Night greybox palette (matches the repo's lobby tones).
local COLOR_FACTORY = Color3.fromRGB(58, 54, 64)
local COLOR_ROOF = Color3.fromRGB(40, 38, 46)
local COLOR_SIGN = Color3.fromRGB(24, 22, 28)
local COLOR_STEEL = Color3.fromRGB(120, 124, 132)
local COLOR_HAZARD = Color3.fromRGB(235, 190, 52)
local COLOR_TEXT_DIM = Color3.fromRGB(185, 185, 190)
local COLOR_TEXT_IDLE = Color3.fromRGB(150, 150, 150)

local function toColor3(rgbTable: { R: number, G: number, B: number }): Color3
	return Color3.fromRGB(rgbTable.R, rgbTable.G, rgbTable.B)
end

type RelFn = (x: number, y: number, z: number) -> Vector3

export type FactoryBuild = {
	spawnLocation: SpawnLocation,
	countdownWall: BasePart,
	statusLabel: TextLabel,
	leaderboardRows: { TextLabel },
	facadeCFrame: CFrame,
	wallSlabCFrame: CFrame,
}

-- Yaw notes (same convention as the rest of the repo): a part's Front is -Z.
-- Yaw 90 -> Front faces -X (west, toward the plaza off the façade) — every
-- west-facing SurfaceGui sign uses this. Block-letter strings instead need
-- yaw -90 (string runs along the CFrame's RightVector; for a reader on the
-- street WEST of the wall, advance must run +Z, i.e. RightVector = +Z).
local YAW_FACE_WEST = CFrame.Angles(0, math.rad(90), 0)
local YAW_LETTERS_READ_FROM_WEST = CFrame.Angles(0, math.rad(-90), 0)

--------------------------------------------------------------------------------
-- Building shell: façade, sides, back, roof, smokestacks, hazard shift door,
-- "Factory" marquee letters + their 2 SpotLights
--------------------------------------------------------------------------------

local function buildShell(factory: Model, rel: RelFn)
	local frontCenterX = FRONT_X + WALL_THICKNESS / 2
	local backCenterX = FRONT_X + BODY_DEPTH - WALL_THICKNESS / 2
	local bodyCenterX = FRONT_X + BODY_DEPTH / 2

	PartKit.MakePart(
		factory,
		"FactoryFront",
		Vector3.new(WALL_THICKNESS, BODY_HEIGHT, FACADE_WIDTH),
		CFrame.new(rel(frontCenterX, BODY_HEIGHT / 2, 0)),
		{ color = COLOR_FACTORY }
	)
	for _, side in { -1, 1 } do
		PartKit.MakePart(
			factory,
			if side > 0 then "FactorySideN" else "FactorySideS",
			Vector3.new(BODY_DEPTH - 2 * WALL_THICKNESS, BODY_HEIGHT, WALL_THICKNESS),
			CFrame.new(rel(bodyCenterX, BODY_HEIGHT / 2, side * (FACADE_WIDTH / 2 - WALL_THICKNESS / 2))),
			{ color = COLOR_FACTORY }
		)
	end
	PartKit.MakePart(
		factory,
		"FactoryBack",
		Vector3.new(WALL_THICKNESS, BODY_HEIGHT, FACADE_WIDTH),
		CFrame.new(rel(backCenterX, BODY_HEIGHT / 2, 0)),
		{ color = COLOR_FACTORY }
	)
	PartKit.MakePart(
		factory,
		"FactoryRoof",
		Vector3.new(BODY_DEPTH, 2, FACADE_WIDTH),
		CFrame.new(rel(bodyCenterX, BODY_HEIGHT + 1, 0)),
		{ color = COLOR_ROOF }
	)

	-- Smokestacks: the skyline silhouette that sells "factory" at night,
	-- staggered heights, planted on the roof (top y 40).
	PartKit.MakeUprightCylinder(factory, "Smokestack1", 18, 7, rel(FRONT_X + 43, BODY_HEIGHT + 11, -44), {
		color = COLOR_FACTORY,
	})
	PartKit.MakeUprightCylinder(factory, "Smokestack2", 24, 6, rel(FRONT_X + 49, BODY_HEIGHT + 14, 38), {
		color = COLOR_FACTORY,
	})

	-- Hazard shift door (decorative — QueuePadService owns the real gate).
	local door = PartKit.MakePart(
		factory,
		"ShiftDoor",
		Vector3.new(14, 14, 0.6),
		CFrame.new(rel(FRONT_X - 0.4, 7, 0)) * YAW_FACE_WEST,
		{ color = COLOR_HAZARD }
	)
	local doorGui = PartKit.MakeSurfaceGui(door, "ShiftDoorGui")
	PartKit.MakeLabel(
		doorGui,
		"Line1",
		"NIGHT SHIFT",
		UDim2.fromScale(0.08, 0.36),
		UDim2.fromScale(0.84, 0.2),
		COLOR_SIGN
	)
	for index, stripeY in { 3.5, 10.5 } do
		PartKit.MakePart(
			factory,
			`ShiftDoorStripe{index}`,
			Vector3.new(0.3, 1.2, 13),
			CFrame.new(rel(FRONT_X - 0.85, stripeY, 0)),
			{ color = COLOR_SIGN, decor = true }
		)
	end

	-- "Factory" marquee: 3D Neon block letters, amber-red, legible from half
	-- the street (SOP §11.1; verbatim string).
	PartKit.MakeBlockLetters(
		factory,
		"Factory",
		CFrame.new(rel(FRONT_X - 0.8, LETTERS_Y, 0)) * YAW_LETTERS_READ_FROM_WEST,
		LobbyConfig.MARQUEE_LETTER_HEIGHT_STUDS,
		toColor3(LobbyConfig.MARQUEE_COLORS.FACTORY)
	)

	-- 2 marquee SpotLights washing the letters and the door from above (the
	-- factory's two feature lights, SOP §2.6; Shadows=false via PartKit).
	for _, side in { -1, 1 } do
		local rig = PartKit.MakePart(
			factory,
			if side > 0 then "MarqueeLightN" else "MarqueeLightS",
			Vector3.new(1.4, 0.7, 1.4),
			CFrame.new(rel(FRONT_X - 1.0, LETTERS_Y + 7.5, side * 20)),
			{ color = COLOR_STEEL, decor = true }
		)
		PartKit.MakeSpot(rig, {
			angle = 70,
			range = 30,
			brightness = 1.5,
			color = toColor3(LobbyConfig.MARQUEE_COLORS.FACTORY),
		})
	end
end

--------------------------------------------------------------------------------
-- Façade signage: CountdownWall slab, "ON SHIFT NOW" status sign,
-- "TOP COLLECTORS" leaderboard
--------------------------------------------------------------------------------

local function buildCountdownWall(factory: Model, rel: RelFn): BasePart
	-- Bare slab — CountdownUI adorns its own SurfaceGui (Face=Front) via the
	-- "CountdownWall" tag, with the literal part name as its legacy fallback.
	local wall = PartKit.MakePart(
		factory,
		"CountdownWall",
		Vector3.new(24, 10, 0.7),
		CFrame.new(rel(FRONT_X - 0.4, 18, -36)) * YAW_FACE_WEST,
		{ color = COLOR_SIGN }
	)
	CollectionService:AddTag(wall, TAG_COUNTDOWN_WALL)
	return wall
end

local function buildStatusSign(factory: Model, rel: RelFn): TextLabel
	local sign = PartKit.MakePart(
		factory,
		"FactoryStatusSign",
		Vector3.new(13, 9, 0.7),
		CFrame.new(rel(FRONT_X - 0.4, 17.5, -16.5)) * YAW_FACE_WEST,
		{ color = COLOR_SIGN }
	)
	local gui = PartKit.MakeSurfaceGui(sign, "FactoryStatusGui")
	PartKit.MakeLabel(
		gui,
		"Title",
		"ON SHIFT NOW",
		UDim2.fromScale(0.05, 0.04),
		UDim2.fromScale(0.9, 0.18),
		COLOR_HAZARD
	)
	local list = PartKit.MakeLabel(
		gui,
		"List",
		"Nobody on shift right now",
		UDim2.fromScale(0.05, 0.26),
		UDim2.fromScale(0.9, 0.68),
		COLOR_TEXT_IDLE
	)
	list.TextYAlignment = Enum.TextYAlignment.Top
	list.TextXAlignment = Enum.TextXAlignment.Left
	list.TextScaled = false
	list.TextSize = 26
	list.TextWrapped = true
	return list
end

local function buildLeaderboard(factory: Model, rel: RelFn): { TextLabel }
	local board = PartKit.MakePart(
		factory,
		"LeaderboardBillboard",
		Vector3.new(28, 16, 0.8),
		CFrame.new(rel(FRONT_X - 0.4, 26, 42)) * YAW_FACE_WEST,
		{ color = COLOR_SIGN }
	)
	local gui = PartKit.MakeSurfaceGui(board, "LeaderboardGui")
	PartKit.MakeLabel(
		gui,
		"Title",
		"TOP COLLECTORS",
		UDim2.fromScale(0.05, 0.02),
		UDim2.fromScale(0.9, 0.12),
		COLOR_HAZARD
	)
	PartKit.MakeLabel(
		gui,
		"Subtitle",
		"Ranked by collection value — rarer pets are worth far more",
		UDim2.fromScale(0.05, 0.15),
		UDim2.fromScale(0.9, 0.05),
		COLOR_TEXT_DIM
	)

	local rows: { TextLabel } = {}
	local rowTop = 0.24
	local rowHeight = (0.97 - rowTop) / LEADERBOARD_ROWS
	for index = 1, LEADERBOARD_ROWS do
		local row = PartKit.MakeLabel(
			gui,
			`Row{index}`,
			"",
			UDim2.fromScale(0.07, rowTop + (index - 1) * rowHeight),
			UDim2.fromScale(0.86, rowHeight * 0.82),
			Color3.fromRGB(225, 225, 225)
		)
		row.TextXAlignment = Enum.TextXAlignment.Left
		table.insert(rows, row)
	end
	return rows
end

--------------------------------------------------------------------------------
-- First-join spawn: plaza, beside the queue pad position, facing the Factory
--------------------------------------------------------------------------------

local function buildSpawn(factory: Model, rel: RelFn): SpawnLocation
	local pad = Instance.new("SpawnLocation")
	pad.Name = "HubSpawn"
	pad.Size = Vector3.new(12, 1, 12)
	-- Default SpawnLocation LookVector is -Z; yaw -90 turns it to +X so every
	-- first-join spawn faces the Factory with the street at their back.
	pad.CFrame = CFrame.new(rel(SPAWN_POSITION_X, 0.5, SPAWN_POSITION_Z)) * CFrame.Angles(0, math.rad(-90), 0)
	pad.Anchored = true
	pad.Neutral = true
	pad.Duration = 0
	pad.Color = Color3.fromRGB(38, 38, 44):Lerp(Color3.fromRGB(80, 220, 120), 0.15)
	pad.TopSurface = Enum.SurfaceType.Smooth
	pad.BottomSurface = Enum.SurfaceType.Smooth
	pad.Parent = factory
	return pad
end

--------------------------------------------------------------------------------
-- Build
--------------------------------------------------------------------------------

function FactoryBuilder.Build(parent: Model, origin: Vector3): FactoryBuild
	local function rel(x: number, y: number, z: number): Vector3
		return origin + Vector3.new(x, y, z)
	end

	local factory = Instance.new("Model")
	factory.Name = "Factory"

	buildShell(factory, rel)
	local countdownWall = buildCountdownWall(factory, rel)
	local statusLabel = buildStatusSign(factory, rel)
	local leaderboardRows = buildLeaderboard(factory, rel)
	local spawnLocation = buildSpawn(factory, rel)

	factory.Parent = parent

	return {
		spawnLocation = spawnLocation,
		countdownWall = countdownWall,
		statusLabel = statusLabel,
		leaderboardRows = leaderboardRows,
		-- Façade west face plane at street center, Front facing the plaza —
		-- QueuePadBuilder anchors the pad/roster board off this.
		facadeCFrame = CFrame.new(rel(FRONT_X, 0, 0)) * YAW_FACE_WEST,
		-- Center of the 48x14 BrainrotWall region on the north façade, Front
		-- facing the queue pad — WallBuilder mounts the slab here.
		wallSlabCFrame = CFrame.new(rel(FRONT_X - 0.5, WALL_SLAB_Y, WALL_SLAB_Z)) * YAW_FACE_WEST,
	}
end

return FactoryBuilder
