--!strict
-- CRYPTLINGS: NIGHT SHIFT — StreetBuilder: the night-street corridor &
-- enclosure greybox (LOBBY_SOP §1.1, §1.2, §1.5, §2.5; build plan WP2.1).
--
-- Builds, at `origin` (= GameConstants.HUB_ORIGIN, passed in by HubService):
--   * the asphalt street (38 wide) with 9-stud sidewalks and dashed lane
--     paint — street axis = X, Factory at the EAST end (matches the old hub
--     orientation so ShiftService's >400-stud "on shift" heuristic holds);
--   * 20 lot pads (45 x 55, raised 0.75 above the sidewalk, 8-stud gaps,
--     10 per side) each with a short footpath ramp from the sidewalk;
--   * the two end-plaza slabs (Factory plaza 100 deep east, Coming Soon
--     forecourt 80 deep west);
--   * the mountain enclosure: 2 staggered WedgePart rows per long side,
--     SOP §1.5 size envelope, ±15° yaw jitter, alternating slate tones,
--     <= 100 wedges total, peaks low behind the lots;
--   * the invisible boundary: CanCollide walls 5 studs inside the mountain
--     line plus full-height caps at both street ends (above-roof escapes);
--   * ~22 street lamps (LobbyConfig.STREET_LAMP spec, tagged "StreetLamp",
--     alternating sides, semi-random offsets, never mirrored pairs, pools
--     spaced >= 0.9 x range) and ONE podium-wash SpotLight per lot — built in
--     the VACANT state (LobbyConfig.LOT_WASH_VACANT) per Addendum 1 Change 1;
--   * per-lot claim fixtures (Addendum 1 Change 1, plan R2 WP2.1): Neon
--     perimeter trim built gray/vacant, a HIDDEN overhead Neon beacon +
--     ball cap, and an invisible nameplate anchor carrying an empty
--     BillboardGui — all tagged (LotTrim/LotBeacon/LotNameplate) with a
--     PlotIndex attribute so the client LotStatusController can join them to
--     the LobbyPlotService "Plot" models and tween claim/vacate states
--     locally. ZERO new Light instances (budget stays exactly 50);
--   * per-lot step plates (Addendum 2 R3-3, plan R3 WP1.1): one walkable
--     6 x 0.35 x 4 plate per lot capping the LotRamp top at the street end
--     of the paving strip, fully street-side of the lot front line, plus 4
--     thin Neon ghost-blue border strips — every number from
--     LobbyConfig.STEP_PLATE (the source of truth shared with the
--     HousePreviewController stand-on-plate predicate), tagged
--     LotStepPlate / LotStepPlateTrim with a PlotIndex attribute. ZERO new
--     Light instances (Neon only); +100 new parts total (5 per lot x 20
--     lots) — the count of record for the WP1.7 part-budget reconciliation.
--
-- Slot contract (preserved): `slots[i] = { index, stationCFrame }` is the
-- exact DisplayStationSlot shape ShelfRoomBuilder consumes via
-- HubService.GetDisplayStationSlots(). stationCFrame sits at the lot center
-- ON the pad top with LookVector toward the street. Indices follow SOP §3.2
-- "lowest index nearest the Factory": 1-10 north side east -> west (1 beside
-- the Factory plaza), 11-20 south side east -> west.
--
-- Pure construction by contract: no signals, no connections, no loops over
-- time, no player logic, no Init/Start — invoked once by HubService in
-- Wave 3. All tunables come from LobbyConfig; every primitive goes through
-- PartKit so the SOP §10/§11 perf + sign rules hold structurally.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local LobbyConfig = require(Shared:WaitForChild("Config"):WaitForChild("LobbyConfig"))

local PartKit = require(script.Parent:WaitForChild("PartKit"))

--------------------------------------------------------------------------------
-- Derived layout (every base number is LobbyConfig's; only arithmetic here).
-- All X/Z figures are origin-relative studs.
--------------------------------------------------------------------------------

-- Lots along X: 10 per side at 45 frontage + 8 gap.
local LOT_PITCH = LobbyConfig.LOT_FRONTAGE_STUDS + LobbyConfig.LOT_GAP_STUDS -- 53
local LOT_SEGMENT = LobbyConfig.LOTS_PER_SIDE * LOT_PITCH - LobbyConfig.LOT_GAP_STUDS -- 522
-- Street runs half a lot-gap past the outermost lots on each end, then the
-- plaza slabs take over: corridor end planes at +/- 265.
local STREET_HALF_LENGTH = (LOT_SEGMENT + LobbyConfig.LOT_GAP_STUDS) / 2 -- 265
local STREET_LENGTH = STREET_HALF_LENGTH * 2 -- 530

local ASPHALT_HALF = LobbyConfig.STREET_ASPHALT_WIDTH_STUDS / 2 -- 19
local CORRIDOR_HALF = LobbyConfig.CORRIDOR_WIDTH_STUDS / 2 -- 28 (asphalt + both sidewalks)

-- Vertical stack: ground base top at y=0; pad top = sidewalk top + the SOP
-- §1.2 raise (0.75) = 1.25 — the stationCFrame plane every lot structure
-- (ShelfRoomBuilder / HousePlan) builds on.
local GROUND_THICKNESS = 2
local ASPHALT_THICKNESS = 0.3
local SIDEWALK_THICKNESS = 0.5
local PAD_TOP_Y = SIDEWALK_THICKNESS + LobbyConfig.LOT_PAD_RAISE_STUDS -- 1.25

-- Lots extend away from the street behind the sidewalks.
local LOT_BACK_Z = CORRIDOR_HALF + LobbyConfig.LOT_DEPTH_STUDS -- 83
local LOT_CENTER_Z = CORRIDOR_HALF + LobbyConfig.LOT_DEPTH_STUDS / 2 -- 55.5
-- Easternmost lot center (column 1, nearest the Factory).
local LOT_EAST_X = LOT_SEGMENT / 2 - LobbyConfig.LOT_FRONTAGE_STUDS / 2 -- 238.5

-- Mountain front line sits a fence-and-breathing-room margin behind the lot
-- back edges; the invisible wall is COLLISION_WALL_INSET_STUDS street-side of
-- it (SOP §1.5) so nobody can summit.
local MOUNTAIN_LINE_Z = LOT_BACK_Z + 9 -- 92
local BOUNDARY_WALL_Z = MOUNTAIN_LINE_Z - LobbyConfig.MOUNTAIN.COLLISION_WALL_INSET_STUDS -- 87
local MOUNTAIN_BACK_ROW_OFFSET = 38 -- second (taller) row this far behind the first
local MOUNTAIN_FRONT_PITCH = 65 -- wedge spacing along X, front row
local MOUNTAIN_BACK_PITCH = 80 -- back row is sparser and X-staggered

-- End plazas (slab depths per SOP §1.3/§1.4; widths sized for the queue pad /
-- fountain / shop cluster east and the Coming Soon forecourt west).
local PLAZA_EAST_DEPTH = LobbyConfig.FACTORY_PLAZA_DEPTH_STUDS -- 100
local PLAZA_WEST_DEPTH = LobbyConfig.COMING_SOON_FORECOURT_DEPTH_STUDS -- 80
local PLAZA_EAST_HALF_WIDTH = 55
local PLAZA_WEST_HALF_WIDTH = 45

-- Mountains flank everything, plazas included.
local MOUNTAIN_WEST_X = -(STREET_HALF_LENGTH + PLAZA_WEST_DEPTH + 5) -- -350
local MOUNTAIN_EAST_X = STREET_HALF_LENGTH + PLAZA_EAST_DEPTH + 5 -- 370

-- Boundary caps just past both end buildings; tall enough to cover roofs.
local BOUNDARY_WALL_HEIGHT = 120
local BOUNDARY_CAP_HEIGHT = 150
local BOUNDARY_CAP_EAST_X = STREET_HALF_LENGTH + PLAZA_EAST_DEPTH + 2 -- 367
local BOUNDARY_CAP_WEST_X = -(STREET_HALF_LENGTH + PLAZA_WEST_DEPTH + 2) -- -347

-- Ground base extends under the mountains on every side.
local GROUND_HALF_X = 400
local GROUND_HALF_Z = 200

-- Lane paint dashes down the street centerline.
local DASH_LENGTH = 5
local DASH_PITCH = 12
local DASH_MARGIN = 10 -- keep paint off the plaza seams

-- Lamp and wash mounting (geometry-local; light specs are LobbyConfig's).
local LAMP_POLE_HEIGHT = 13
local LAMP_Z = CORRIDOR_HALF - 1 -- 27, the sidewalk's outer band
local WASH_MOUNT_HEIGHT = 18 -- one SpotLight per lot, aimed down at the pad

-- Step-plate border strip height (geometry-local; the plate dimensions of
-- record live in LobbyConfig.STEP_PLATE — never re-literaled here).
local STEP_TRIM_HEIGHT = 0.1

-- Deterministic semi-random jitter (mountains, lamp offsets): same build
-- every server, matching the FloorGen seeded-rng convention.
local BUILD_SEED = 0x57AB1E

--------------------------------------------------------------------------------
-- Night greybox palette (level-art only; thematic colors live in LobbyConfig)
--------------------------------------------------------------------------------

local COLOR_GROUND = Color3.fromRGB(46, 58, 40) -- dark night grass
local COLOR_LOT_GRASS = Color3.fromRGB(58, 86, 48) -- vacant-lot lawn tone
local COLOR_ASPHALT = Color3.fromRGB(38, 38, 44)
local COLOR_SIDEWALK = Color3.fromRGB(78, 78, 86)
local COLOR_PLAZA = Color3.fromRGB(52, 52, 60)
local COLOR_LANE_PAINT = Color3.fromRGB(225, 215, 160)
local COLOR_STEEL = Color3.fromRGB(120, 124, 132)
-- Vacant-state fixture gray (claimed accent colors are tweened client-side by
-- LotStatusController from LobbyConfig.LOT_OWNER_ACCENTS — never set here).
local COLOR_FIXTURE_GRAY = Color3.fromRGB(128, 130, 138)
-- Step-plate top: dark SmoothPlastic so the Neon ghost-blue border carries
-- the read (Addendum 2 R3-3; border color of record = STEP_PLATE.BORDER_COLOR).
local COLOR_STEP_PLATE = Color3.fromRGB(36, 38, 46)

local TAG_STREET_LAMP = "StreetLamp"
local TAG_LOT_WASH = "LotWash"
local TAG_LOT_TRIM = "LotTrim"
local TAG_LOT_BEACON = "LotBeacon"
local TAG_LOT_NAMEPLATE = "LotNameplate"
local TAG_LOT_STEP_PLATE = "LotStepPlate"
local TAG_LOT_STEP_TRIM = "LotStepPlateTrim"

--------------------------------------------------------------------------------
-- Types
--------------------------------------------------------------------------------

-- The exact DisplayStationSlot shape HubService re-exposes to ShelfRoomBuilder.
export type StreetSlot = { index: number, stationCFrame: CFrame }

-- Per-lot claim fixtures (Addendum 1 Change 1; R2 Wave-2 interface contract).
-- LotStatusController joins these to the "Plot" models by PlotIndex and owns
-- every claim/vacate property tween — the server never animates them.
export type LotFixture = {
	washLight: SpotLight,
	trimParts: { BasePart },
	beaconParts: { BasePart },
	nameplateAnchor: BasePart,
}

export type StreetBuildResult = {
	model: Model,
	boundary: Model, -- HubService may want this Persistent (walls must never stream out)
	slots: { StreetSlot },
	lotFixtures: { LotFixture }, -- [lot index 1-20], same indexing as slots
	-- Plaza slab top centers, LookVector toward the street — anchor frames for
	-- FactoryBuilder / ComingSoonBuilder / HubService layout decisions.
	factoryPlazaCFrame: CFrame,
	comingSoonForecourtCFrame: CFrame,
	streetEastX: number, -- absolute world X of the street/plaza seams
	streetWestX: number,
	corridorHalfWidth: number,
}

type Rel = (x: number, y: number, z: number) -> Vector3

local StreetBuilder = {}

--------------------------------------------------------------------------------
-- Ground: base plate, asphalt, sidewalks, lane paint, end-plaza slabs
--------------------------------------------------------------------------------

local function buildGround(parent: Model, rel: Rel)
	local base = PartKit.MakePart(
		parent,
		"GroundBase",
		Vector3.new(GROUND_HALF_X * 2, GROUND_THICKNESS, GROUND_HALF_Z * 2),
		CFrame.new(rel(0, -GROUND_THICKNESS / 2, 0)),
		{ color = COLOR_GROUND }
	)
	base.Material = Enum.Material.Grass

	local street = PartKit.MakePart(
		parent,
		"Street",
		Vector3.new(STREET_LENGTH, ASPHALT_THICKNESS, ASPHALT_HALF * 2),
		CFrame.new(rel(0, ASPHALT_THICKNESS / 2, 0)),
		{ color = COLOR_ASPHALT }
	)
	street.Material = Enum.Material.Asphalt

	for _, side in { 1, -1 } do
		local walk = PartKit.MakePart(
			parent,
			if side > 0 then "SidewalkN" else "SidewalkS",
			Vector3.new(STREET_LENGTH, SIDEWALK_THICKNESS, LobbyConfig.SIDEWALK_WIDTH_STUDS),
			CFrame.new(rel(0, SIDEWALK_THICKNESS / 2, side * (ASPHALT_HALF + LobbyConfig.SIDEWALK_WIDTH_STUDS / 2))),
			{ color = COLOR_SIDEWALK }
		)
		walk.Material = Enum.Material.Concrete
	end

	-- Dashed center line (decor: no collision, no shadows).
	local dashIndex = 0
	local x = -(STREET_HALF_LENGTH - DASH_MARGIN)
	while x <= STREET_HALF_LENGTH - DASH_MARGIN do
		dashIndex += 1
		PartKit.MakePart(
			parent,
			`LaneDash{dashIndex}`,
			Vector3.new(DASH_LENGTH, 0.05, 0.7),
			CFrame.new(rel(x, ASPHALT_THICKNESS + 0.025, 0)),
			{ color = COLOR_LANE_PAINT, decor = true }
		)
		x += DASH_PITCH
	end
end

local function buildPlazas(parent: Model, rel: Rel)
	local east = PartKit.MakePart(
		parent,
		"FactoryPlaza",
		Vector3.new(PLAZA_EAST_DEPTH, ASPHALT_THICKNESS, PLAZA_EAST_HALF_WIDTH * 2),
		CFrame.new(rel(STREET_HALF_LENGTH + PLAZA_EAST_DEPTH / 2, ASPHALT_THICKNESS / 2, 0)),
		{ color = COLOR_PLAZA }
	)
	east.Material = Enum.Material.Concrete

	local west = PartKit.MakePart(
		parent,
		"ComingSoonForecourt",
		Vector3.new(PLAZA_WEST_DEPTH, ASPHALT_THICKNESS, PLAZA_WEST_HALF_WIDTH * 2),
		CFrame.new(rel(-(STREET_HALF_LENGTH + PLAZA_WEST_DEPTH / 2), ASPHALT_THICKNESS / 2, 0)),
		{ color = COLOR_PLAZA }
	)
	west.Material = Enum.Material.Concrete
end

--------------------------------------------------------------------------------
-- Lots: raised pad + footpath ramp + R3-3 step plate + ONE podium-wash
-- SpotLight per lot (built VACANT) + the Addendum 1 Change 1 claim fixtures
-- (gray Neon trim, hidden beacon, nameplate anchor). Returns the
-- DisplayStationSlot list (index 1 nearest the Factory, SOP §3.2) plus the
-- per-lot fixture table.
--------------------------------------------------------------------------------

-- Neon perimeter trim: 4 strips (LOT_TRIM.WIDTH x LOT_TRIM.THICK profile)
-- framing the 45x55 pad edge on the pad top — built gray at the vacant
-- transparency; side strips are corner-shortened so strips never overlap.
local function buildLotTrim(parent: Instance, rel: Rel, index: number, x: number, zCenter: number): { BasePart }
	local trimSpec = LobbyConfig.LOT_TRIM
	local trimY = PAD_TOP_Y + trimSpec.THICK / 2
	local halfFrontage = LobbyConfig.LOT_FRONTAGE_STUDS / 2
	local halfDepth = LobbyConfig.LOT_DEPTH_STUDS / 2
	local sideLength = LobbyConfig.LOT_DEPTH_STUDS - 2 * trimSpec.WIDTH

	local trimParts: { BasePart } = {}
	for _, edge in { -1, 1 } do
		-- Frontage-axis strips (full 45-stud runs at the street/back edges)...
		table.insert(
			trimParts,
			PartKit.MakePart(
				parent,
				`LotTrimZ{index}`,
				Vector3.new(LobbyConfig.LOT_FRONTAGE_STUDS, trimSpec.THICK, trimSpec.WIDTH),
				CFrame.new(rel(x, trimY, zCenter + edge * (halfDepth - trimSpec.WIDTH / 2))),
				{ color = COLOR_FIXTURE_GRAY, material = Enum.Material.Neon, decor = true }
			)
		)
		-- ...plus the corner-shortened depth-axis strips.
		table.insert(
			trimParts,
			PartKit.MakePart(
				parent,
				`LotTrimX{index}`,
				Vector3.new(trimSpec.WIDTH, trimSpec.THICK, sideLength),
				CFrame.new(rel(x + edge * (halfFrontage - trimSpec.WIDTH / 2), trimY, zCenter)),
				{ color = COLOR_FIXTURE_GRAY, material = Enum.Material.Neon, decor = true }
			)
		)
	end

	for _, strip in trimParts do
		strip.Transparency = trimSpec.VACANT_TRANSPARENCY
		strip:SetAttribute("PlotIndex", index)
		CollectionService:AddTag(strip, TAG_LOT_TRIM)
	end
	return trimParts
end

-- Overhead claim beacon, built HIDDEN (Transparency 1): Neon cylinder + ball
-- cap over the lot center (height cap 35 — the 60-stud queue beacon stays the
-- tallest landmark), plus the invisible nameplate anchor carrying an empty
-- BillboardGui that LotStatusController fills/show-hides.
local function buildLotBeacon(
	parent: Instance,
	rel: Rel,
	index: number,
	x: number,
	zCenter: number
): ({ BasePart }, BasePart)
	local beaconSpec = LobbyConfig.LOT_BEACON

	local pillar = PartKit.MakeUprightCylinder(
		parent,
		`LotBeacon{index}`,
		beaconSpec.HEIGHT,
		beaconSpec.DIAMETER,
		rel(x, PAD_TOP_Y + beaconSpec.HEIGHT / 2, zCenter),
		{ color = COLOR_FIXTURE_GRAY, material = Enum.Material.Neon, transparency = 1, decor = true }
	)
	local cap = PartKit.MakePart(
		parent,
		`LotBeaconCap{index}`,
		Vector3.new(beaconSpec.CAP_DIAMETER, beaconSpec.CAP_DIAMETER, beaconSpec.CAP_DIAMETER),
		CFrame.new(rel(x, PAD_TOP_Y + beaconSpec.HEIGHT + beaconSpec.CAP_DIAMETER / 2, zCenter)),
		{ color = COLOR_FIXTURE_GRAY, material = Enum.Material.Neon, transparency = 1, decor = true }
	)
	cap.Shape = Enum.PartType.Ball

	local beaconParts: { BasePart } = { pillar, cap }
	for _, part in beaconParts do
		part:SetAttribute("PlotIndex", index)
		CollectionService:AddTag(part, TAG_LOT_BEACON)
	end

	local nameplateAnchor = PartKit.MakePart(
		parent,
		`LotNameplate{index}`,
		Vector3.one,
		CFrame.new(rel(x, beaconSpec.NAMEPLATE_HEIGHT, zCenter)),
		{ transparency = 1, decor = true }
	)
	PartKit.MakeBillboard(nameplateAnchor, beaconSpec.NAMEPLATE_MAX_DISTANCE, { "" }, { name = "LotNameplate" })
	nameplateAnchor:SetAttribute("PlotIndex", index)
	CollectionService:AddTag(nameplateAnchor, TAG_LOT_NAMEPLATE)

	return beaconParts, nameplateAnchor
end

-- Step plate (Addendum 2 R3-3, plan R3 WP1.1): one walkable cap per lot at
-- the street end of the paving strip, fully street-side of the lot front
-- line. Every dimension is LobbyConfig.STEP_PLATE's — the single source of
-- truth shared with the HousePreviewController stand-on-plate predicate —
-- and placement derives from the SAME slot-anchor CFrame the client mirror
-- exposes (stationCFrame * CFrame.new(0, ·, LOCAL_Z)), so server geometry
-- and client math can never drift. LOCAL_Z = -29.5 (plot-local, -Z
-- streetward, = -(LOT_DEPTH_STUDS/2 + DEPTH/2)) lands the plate at world
-- |z| ~ 26, capping the LotRamp top (ramp spans |z| 25..28) as a literal
-- step; the plate's lot-side edge exactly kisses the lot front line, so
-- the client's interior veto can never fight the stand-on-plate predicate.
-- Plate top = PAD_TOP_Y + PROUD_STUDS (1.25 + 0.25 = 1.5). The plate
-- collides (it IS the step) but never queries/touches; the 4 Neon border
-- strips framing its top perimeter are decor-flagged ghost blue
-- (== COLOR_GHOST, so step and ghost preview read as one system).
-- ZERO Light instances — Neon material only.
local function buildLotStepPlate(parent: Instance, index: number, stationCFrame: CFrame)
	local plateSpec = LobbyConfig.STEP_PLATE

	local plate = PartKit.MakePart(
		parent,
		`LotStepPlate{index}`,
		Vector3.new(plateSpec.WIDTH, plateSpec.HEIGHT, plateSpec.DEPTH),
		stationCFrame * CFrame.new(0, plateSpec.PROUD_STUDS - plateSpec.HEIGHT / 2, plateSpec.LOCAL_Z),
		{ color = COLOR_STEP_PLATE, canQuery = false, canTouch = false }
	)
	plate:SetAttribute("PlotIndex", index)
	CollectionService:AddTag(plate, TAG_LOT_STEP_PLATE)

	-- Border: 4 thin Neon strips framing the plate top perimeter; the
	-- depth-axis pair is corner-shortened so strips never overlap (the
	-- buildLotTrim idiom).
	local borderColor = Color3.fromRGB(plateSpec.BORDER_COLOR.R, plateSpec.BORDER_COLOR.G, plateSpec.BORDER_COLOR.B)
	local trimY = plateSpec.PROUD_STUDS + STEP_TRIM_HEIGHT / 2
	local trimParts: { BasePart } = {}
	for _, edge in { -1, 1 } do
		table.insert(
			trimParts,
			PartKit.MakePart(
				parent,
				`LotStepPlateTrimZ{index}`,
				Vector3.new(plateSpec.WIDTH, STEP_TRIM_HEIGHT, plateSpec.BORDER_THICKNESS),
				stationCFrame
					* CFrame.new(
						0,
						trimY,
						plateSpec.LOCAL_Z + edge * (plateSpec.DEPTH / 2 - plateSpec.BORDER_THICKNESS / 2)
					),
				{ color = borderColor, material = Enum.Material.Neon, decor = true }
			)
		)
		table.insert(
			trimParts,
			PartKit.MakePart(
				parent,
				`LotStepPlateTrimX{index}`,
				Vector3.new(
					plateSpec.BORDER_THICKNESS,
					STEP_TRIM_HEIGHT,
					plateSpec.DEPTH - 2 * plateSpec.BORDER_THICKNESS
				),
				stationCFrame
					* CFrame.new(
						edge * (plateSpec.WIDTH / 2 - plateSpec.BORDER_THICKNESS / 2),
						trimY,
						plateSpec.LOCAL_Z
					),
				{ color = borderColor, material = Enum.Material.Neon, decor = true }
			)
		)
	end
	for _, strip in trimParts do
		strip:SetAttribute("PlotIndex", index)
		CollectionService:AddTag(strip, TAG_LOT_STEP_TRIM)
	end
end

local function buildLots(parent: Model, rel: Rel): ({ StreetSlot }, { LotFixture })
	local lotsModel = Instance.new("Model")
	lotsModel.Name = "PlayerLots"

	local slots: { StreetSlot } = {}
	local lotFixtures: { LotFixture } = {}
	local lotCount = LobbyConfig.LOTS_PER_SIDE * 2

	for index = 1, lotCount do
		local sideNorth = index <= LobbyConfig.LOTS_PER_SIDE
		local column = if sideNorth then index else index - LobbyConfig.LOTS_PER_SIDE
		local sign = if sideNorth then 1 else -1
		-- Column 1 = easternmost = beside the Factory plaza (lowest index
		-- nearest the Factory); columns march west from there.
		local x = LOT_EAST_X - (column - 1) * LOT_PITCH
		local zCenter = sign * LOT_CENTER_Z

		-- Raised lot pad: top face is the build plane for every lot structure.
		local pad = PartKit.MakePart(
			lotsModel,
			`LotPad{index}`,
			Vector3.new(LobbyConfig.LOT_FRONTAGE_STUDS, PAD_TOP_Y, LobbyConfig.LOT_DEPTH_STUDS),
			CFrame.new(rel(x, PAD_TOP_Y / 2, zCenter)),
			{ color = COLOR_LOT_GRASS }
		)
		pad.Material = Enum.Material.Grass

		-- Short footpath: a walkable ramp from the sidewalk up the pad raise
		-- (wedge slope descends toward the street) ...
		PartKit.MakeWedge(
			lotsModel,
			`LotRamp{index}`,
			Vector3.new(4, LobbyConfig.LOT_PAD_RAISE_STUDS, 3),
			CFrame.new(rel(x, SIDEWALK_THICKNESS + LobbyConfig.LOT_PAD_RAISE_STUDS / 2, sign * (CORRIDOR_HALF - 1.5)))
				* CFrame.Angles(0, if sideNorth then 0 else math.pi, 0),
			{ color = COLOR_SIDEWALK }
		)
		-- ... plus a thin paving strip leading onto the lawn.
		PartKit.MakePart(
			lotsModel,
			`LotPath{index}`,
			Vector3.new(4, 0.06, 10),
			CFrame.new(rel(x, PAD_TOP_Y + 0.03, sign * (CORRIDOR_HALF + 5))),
			{ color = COLOR_SIDEWALK, decor = true }
		)

		-- Slot anchor: lot center at PAD TOP, LookVector toward the street.
		-- Computed here (not at the loop tail) because the R3-3 step plate
		-- derives from this exact transform — the same one the client
		-- predicate reads via the LobbyPlotService "Plot" mirror.
		local basePos = rel(x, PAD_TOP_Y, zCenter)
		local stationCFrame = CFrame.lookAt(basePos, basePos + Vector3.new(0, 0, -sign))

		-- Step plate + Neon border capping the LotRamp top (Addendum 2 R3-3).
		buildLotStepPlate(lotsModel, index, stationCFrame)

		-- ONE podium-wash SpotLight per lot, aimed straight down at the pad
		-- (SOP §2.6 — never a light per podium), BUILT in the VACANT state
		-- (Addendum 1 Change 1): same instance count as ever (still 20, still
		-- the exact same Light census); claim/vacate is a client-side property
		-- tween by LotStatusController, never a runtime Light create/destroy.
		local washSpec = LobbyConfig.LOT_WASH_VACANT
		local washMount = PartKit.MakePart(
			lotsModel,
			`LotWash{index}`,
			Vector3.new(1, 1, 1),
			CFrame.new(rel(x, WASH_MOUNT_HEIGHT, zCenter)),
			{ transparency = 1, decor = true }
		)
		local washLight = PartKit.MakeSpot(washMount, {
			angle = washSpec.ANGLE,
			range = washSpec.RANGE,
			brightness = washSpec.BRIGHTNESS,
			color = Color3.fromRGB(washSpec.COLOR.R, washSpec.COLOR.G, washSpec.COLOR.B),
		})
		washMount:SetAttribute("PlotIndex", index)
		CollectionService:AddTag(washMount, TAG_LOT_WASH)

		-- Claim fixtures: gray Neon trim + hidden beacon + nameplate anchor.
		local trimParts = buildLotTrim(lotsModel, rel, index, x, zCenter)
		local beaconParts, nameplateAnchor = buildLotBeacon(lotsModel, rel, index, x, zCenter)
		table.insert(lotFixtures, {
			washLight = washLight,
			trimParts = trimParts,
			beaconParts = beaconParts,
			nameplateAnchor = nameplateAnchor,
		})

		table.insert(slots, { index = index, stationCFrame = stationCFrame })
	end

	assert(#slots == lotCount, "[StreetBuilder] lot slot count drifted from spec")
	assert(#lotFixtures == lotCount, "[StreetBuilder] lot fixture count drifted from spec")
	lotsModel.Parent = parent
	return slots, lotFixtures
end

--------------------------------------------------------------------------------
-- Street lamps: LobbyConfig.STREET_LAMP spec — alternating sides, semi-random
-- offsets (never mirrored pairs), same-side pools spaced >= 0.9 x range.
--------------------------------------------------------------------------------

local function buildStreetLamp(parent: Model, index: number, position: Vector3, sign: number)
	local lampSpec = LobbyConfig.STREET_LAMP
	local lamp = Instance.new("Model")
	lamp.Name = `StreetLamp{index}`

	PartKit.MakeUprightCylinder(
		lamp,
		"Pole",
		LAMP_POLE_HEIGHT,
		0.7,
		position + Vector3.new(0, LAMP_POLE_HEIGHT / 2, 0),
		{ color = COLOR_STEEL }
	)
	PartKit.MakePart(
		lamp,
		"Arm",
		Vector3.new(0.5, 0.5, 3),
		CFrame.new(position + Vector3.new(0, LAMP_POLE_HEIGHT - 0.2, -sign * 1.5)),
		{ color = COLOR_STEEL, decor = true }
	)
	local bulb = PartKit.MakePart(
		lamp,
		"Bulb",
		Vector3.new(1.8, 0.9, 1.8),
		CFrame.new(position + Vector3.new(0, LAMP_POLE_HEIGHT - 0.4, -sign * 3)),
		{
			color = Color3.fromRGB(lampSpec.BULB_COLOR.R, lampSpec.BULB_COLOR.G, lampSpec.BULB_COLOR.B),
			material = Enum.Material.Neon,
			decor = true,
		}
	)
	PartKit.MakeSpot(bulb, {
		angle = lampSpec.ANGLE,
		range = lampSpec.RANGE,
		brightness = lampSpec.BRIGHTNESS,
		color = Color3.fromRGB(lampSpec.COLOR.R, lampSpec.COLOR.G, lampSpec.COLOR.B),
	})

	CollectionService:AddTag(lamp, TAG_STREET_LAMP)
	lamp.Parent = parent
end

local function buildStreetLamps(parent: Model, rel: Rel, rng: Random)
	local lampSpec = LobbyConfig.STREET_LAMP
	local lampsPerSide = lampSpec.COUNT // 2 -- 11 per side
	local pitch = LOT_SEGMENT / (lampsPerSide - 1) -- 52.2 same-side spacing

	-- Pools must stay >= MIN_POOL_SPACING_FACTOR x range even at worst-case
	-- opposing jitter (SOP §2.5 "pools just kiss, never double-lit").
	assert(
		pitch - 2 * lampSpec.OFFSET_JITTER_STUDS >= lampSpec.MIN_POOL_SPACING_FACTOR * lampSpec.RANGE,
		"[StreetBuilder] lamp pitch violates the pool-spacing rule"
	)

	local lampIndex = 0
	for k = 0, lampsPerSide - 1 do
		-- North row anchors on the lot grid; south row runs a half-pitch
		-- stagger east — alternating sides every ~26 studs down the street,
		-- with independent jitter so no pair ever mirrors.
		local northX = -LOT_SEGMENT / 2
			+ k * pitch
			+ rng:NextNumber(-lampSpec.OFFSET_JITTER_STUDS, lampSpec.OFFSET_JITTER_STUDS)
		local southX = -LOT_SEGMENT / 2
			+ pitch / 2
			+ k * pitch
			+ rng:NextNumber(-lampSpec.OFFSET_JITTER_STUDS, lampSpec.OFFSET_JITTER_STUDS)

		lampIndex += 1
		buildStreetLamp(parent, lampIndex, rel(northX, 0, LAMP_Z), 1)
		lampIndex += 1
		buildStreetLamp(parent, lampIndex, rel(southX, 0, -LAMP_Z), -1)
	end
end

--------------------------------------------------------------------------------
-- Mountain enclosure: 2 staggered wedge rows per long side (SOP §1.5).
-- Front row low (stars stay visible above the lots), back row tall.
--------------------------------------------------------------------------------

local function buildMountainRow(
	parent: Model,
	rel: Rel,
	rng: Random,
	sign: number, -- +1 north side, -1 south side
	rowOffsetZ: number,
	pitch: number,
	startStagger: number,
	heightMin: number,
	heightMax: number,
	counter: { count: number }
)
	local mountain = LobbyConfig.MOUNTAIN
	local x = MOUNTAIN_WEST_X + startStagger
	while x <= MOUNTAIN_EAST_X do
		counter.count += 1
		assert(counter.count <= mountain.WEDGE_BUDGET, "[StreetBuilder] mountain wedge budget exceeded")

		local width = rng:NextNumber(mountain.WIDTH_MIN_STUDS, mountain.WIDTH_MAX_STUDS)
		local height = rng:NextNumber(heightMin, heightMax)
		local depth = rng:NextNumber(mountain.DEPTH_MIN_STUDS, mountain.DEPTH_MAX_STUDS)
		local yawJitter = math.rad(rng:NextNumber(-mountain.YAW_JITTER_DEGREES, mountain.YAW_JITTER_DEGREES))
		-- Wedge slope descends toward its Front (-Z): face the street so the
		-- silhouette ramps up and away from the lots.
		local baseYaw = if sign > 0 then 0 else math.pi
		local color = if counter.count % 2 == 0 then mountain.COLOR_A else mountain.COLOR_B

		PartKit.MakeWedge(
			parent,
			`Mountain{counter.count}`,
			Vector3.new(width, height, depth),
			CFrame.new(rel(x, height / 2 - 1.5, sign * (MOUNTAIN_LINE_Z + rowOffsetZ + depth / 2)))
				* CFrame.Angles(0, baseYaw + yawJitter, 0),
			{ color = Color3.fromRGB(color.R, color.G, color.B), material = Enum.Material.Slate, decor = true }
		)

		x += pitch
	end
end

local function buildMountains(parent: Model, rel: Rel, rng: Random)
	local mountain = LobbyConfig.MOUNTAIN
	local model = Instance.new("Model")
	model.Name = "Mountains"

	local counter = { count = 0 }
	local frontHeightMax = mountain.HEIGHT_MIN_STUDS + 28 -- 50-78: peaks low behind lots
	local backHeightMin = mountain.HEIGHT_MAX_STUDS - 40 -- 80-120: the skyline row

	for _, sign in { 1, -1 } do
		buildMountainRow(
			model,
			rel,
			rng,
			sign,
			0,
			MOUNTAIN_FRONT_PITCH,
			0,
			mountain.HEIGHT_MIN_STUDS,
			frontHeightMax,
			counter
		)
		buildMountainRow(
			model,
			rel,
			rng,
			sign,
			MOUNTAIN_BACK_ROW_OFFSET,
			MOUNTAIN_BACK_PITCH,
			MOUNTAIN_BACK_PITCH / 2,
			backHeightMin,
			mountain.HEIGHT_MAX_STUDS,
			counter
		)
	end

	model.Parent = parent
end

--------------------------------------------------------------------------------
-- Invisible boundary: CanCollide walls 5 studs inside the mountain line on
-- both long sides + full-height caps just past both end buildings (covers
-- every above-roof escape; the Factory / Coming Soon shells block at grade).
-- CanQuery stays false so camera raycasts pass straight through.
--------------------------------------------------------------------------------

local function buildBoundary(parent: Model, rel: Rel): Model
	local boundary = Instance.new("Model")
	boundary.Name = "Boundary"

	local wallProps = {
		transparency = 1,
		canCollide = true,
		canTouch = false,
		canQuery = false,
		castShadow = false,
	}
	local sideLength = BOUNDARY_CAP_EAST_X - BOUNDARY_CAP_WEST_X
	local sideCenterX = (BOUNDARY_CAP_EAST_X + BOUNDARY_CAP_WEST_X) / 2

	for _, side in { 1, -1 } do
		PartKit.MakePart(
			boundary,
			if side > 0 then "BoundaryWallN" else "BoundaryWallS",
			Vector3.new(sideLength, BOUNDARY_WALL_HEIGHT, 2),
			CFrame.new(rel(sideCenterX, BOUNDARY_WALL_HEIGHT / 2, side * BOUNDARY_WALL_Z)),
			wallProps
		)
	end

	for _, capX in { BOUNDARY_CAP_EAST_X, BOUNDARY_CAP_WEST_X } do
		PartKit.MakePart(
			boundary,
			if capX > 0 then "BoundaryCapE" else "BoundaryCapW",
			Vector3.new(2, BOUNDARY_CAP_HEIGHT, BOUNDARY_WALL_Z * 2),
			CFrame.new(rel(capX, BOUNDARY_CAP_HEIGHT / 2, 0)),
			wallProps
		)
	end

	boundary.Parent = parent
	return boundary
end

--------------------------------------------------------------------------------
-- Build
--------------------------------------------------------------------------------

function StreetBuilder.Build(parent: Model, origin: Vector3): StreetBuildResult
	local function rel(x: number, y: number, z: number): Vector3
		return origin + Vector3.new(x, y, z)
	end

	local rng = Random.new(BUILD_SEED)

	local model = Instance.new("Model")
	model.Name = "Street"

	buildGround(model, rel)
	buildPlazas(model, rel)
	local slots, lotFixtures = buildLots(model, rel)
	buildStreetLamps(model, rel, rng)
	buildMountains(model, rel, rng)
	local boundary = buildBoundary(model, rel)

	model.Parent = parent

	local eastTop = rel(STREET_HALF_LENGTH + PLAZA_EAST_DEPTH / 2, ASPHALT_THICKNESS, 0)
	local westTop = rel(-(STREET_HALF_LENGTH + PLAZA_WEST_DEPTH / 2), ASPHALT_THICKNESS, 0)

	return {
		model = model,
		boundary = boundary,
		slots = slots,
		lotFixtures = lotFixtures,
		factoryPlazaCFrame = CFrame.lookAt(eastTop, eastTop + Vector3.new(-1, 0, 0)),
		comingSoonForecourtCFrame = CFrame.lookAt(westTop, westTop + Vector3.new(1, 0, 0)),
		streetEastX = origin.X + STREET_HALF_LENGTH,
		streetWestX = origin.X - STREET_HALF_LENGTH,
		corridorHalfWidth = CORRIDOR_HALF,
	}
end

return StreetBuilder
