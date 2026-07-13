--!strict
-- CRYPTLINGS: NIGHT SHIFT — R5 house/lot plan data (WP2.1; plan of record
-- LOBBY_BUILD_PLAN_R5.md D1-D10, spec LOBBY_SOP_ADDENDUM_4.md §1/§3/§4/§6).
-- The ONE geometric source of truth shared by the server lot builder
-- (ShelfRoomBuilder) and the client ghost preview (HousePreviewController).
--
-- Pure Luau: no Roblox globals (lune-safe), no Instances, no yields, NO
-- Color3 — colors are frozen {R,G,B} tables from LobbyConfig.HOUSE_PALETTE,
-- converted via Color3.fromRGB at APPLY time only (raw-table-to-Color3 is
-- the recurring boot-crash class). All results memoized frozen tables.
--
-- Coordinate frame: lot-local; x = frontage, z = depth (-Z faces the
-- street), y up from the pad top.
--
--   SlotCount(tier) -> number                 (8 / 12 / 24 / 60, of record)
--   SlotLayouts(tier) -> { SlotLayout }       (§3 gallery loop; ids s1..sN,
--                                              per floor z asc then x asc,
--                                              floors ground-up)
--   ShellPlan(tier) -> Shell                  (D2 five-list contract)
--   Footprint(tier) -> Footprint              (D3 footprints + D6 heights)
--   GhostPlan(tier) -> { ShellPart }          (exterior walls + parapet +
--                                              roof slabs + bulkhead ONLY)
--   StairKeepClears(tier) -> { KeepClear }    (§2.3 arrival pad / run-bottom
--                                              / core rect)
--   EstimateShellParts(tier) -> number        (sum of the five Shell lists)
--   EstimateParts(tier) -> number             (whole lot: shell + podiums +
--                                              dressing/sign allowance; the
--                                              PART_BUDGET_HOUSE_BY_TIER bind)
--
-- Tier designs (Addendum 4 §1): T1 "Neon Ranch Showroom" 33x30, T2
-- "Brownstone Townhouse" 37x38, T3 "Crypt Spire Mansion" 41x45. Circulation
-- is the §2 U-switchback stair core composed from HousePlanStairs.Generate
-- per tier; every slab above floor 1 (roof included) L-cuts the full 13x14
-- shaft (2 rects). The old WedgePart ramp path (RAMP_*), the U-perimeter
-- mansion floor (U_*/SIDE_COLUMN_Z) and the single-mass HOUSE_WIDTH/DEPTH/
-- CENTER_Z exports are DELETED (plan D2/D7).

local GameConstants = require("../Config/GameConstants")
local LobbyConfig = require("../Config/LobbyConfig")
local StairCore = require("./HousePlanStairs")

export type SlotLayout = {
	slotId: string,
	slotLabel: string,
	x: number,
	y: number,
	z: number,
}

export type Dim3 = { X: number, Y: number, Z: number }
export type RGB = { R: number, G: number, B: number }

-- D2 ShellPart/Shell contract (verbatim shape of record).
export type ShellPart = {
	size: Dim3,
	offset: Dim3, -- part center, lot-local frame
	orientation: Dim3?, -- degrees; builder/ghost apply CFrame.new(offset) * CFrame.Angles(rad(X), rad(Y), rad(Z)); nil = axis-aligned
	color: RGB?, -- frozen {R,G,B} 0-255, Color3.fromRGB at APPLY time only; nil = category default
}

export type Shell = {
	floors: number,
	walls: { ShellPart }, -- solid vertical, CanCollide
	slabs: { ShellPart }, -- solid horizontal, CanCollide
	stairs: { ShellPart }, -- inclined planks + landings + entry stoops, CanCollide
	windows: { ShellPart }, -- applied 0.3-thick Neon panels; decor, no collide
	neon: { ShellPart }, -- all other Neon dressing; decor, no collide
}

export type Rect = StairCore.Rect
export type KeepClear = StairCore.KeepClear

export type Footprint = {
	width: number,
	depth: number,
	centerZ: number,
	frontZ: number,
	backZ: number,
	ffl1: number,
	roofTop: number,
	parapetTop: number,
	bulkheadTop: number,
}

--------------------------------------------------------------------------------
-- Constants of record (LobbyConfig.HOUSE / HOUSE_PALETTE own the numbers;
-- the per-tier design tables below transcribe Addendum 4 §1/§3/§4)
--------------------------------------------------------------------------------

local LOT_FRONTAGE = LobbyConfig.LOT_FRONTAGE_STUDS -- 45 (x)
local LOT_DEPTH = LobbyConfig.LOT_DEPTH_STUDS -- 55 (z)
local PODIUM_SPACING = LobbyConfig.PODIUM.SPACING_STUDS -- 5 minimum
local PLINTH_RADIUS = LobbyConfig.PODIUM.PLINTH_DIAMETER_STUDS / 2 -- 1.5

local HOUSE = LobbyConfig.HOUSE
local PALETTE = LobbyConfig.HOUSE_PALETTE

local SHELL_CLEARANCE = 2 -- tall parts stay this far inside the lot edge (D5)
local FLOOR_PITCH = HOUSE.FLOOR_PITCH_STUDS -- 10 (9 wall + 1 slab, D3)
local WALL_HEIGHT = HOUSE.WALL_HEIGHT_STUDS -- 9
local SLAB_THICKNESS = HOUSE.SLAB_THICKNESS_STUDS -- 1
local WALL_THICKNESS = 1
local FFL1_BY_TIER = HOUSE.FFL1_BY_TIER -- { 1, 3, 3 }

local DOOR_WIDTH = 7 -- §2.3 front door 7w x 7h
local DOOR_HEIGHT = 7
local TERRACE_DOOR_WIDTH = 6 -- §2.3 bulkhead/terrace doors 6w x 7h
local PARAPET_HEIGHT = 4 -- §4 (binding minimum 3; 4 reads from the street)
local GUARD_HEIGHT = 3 -- §4 terrace rails
local WINDOW_THICKNESS = 0.3 -- §1.0 applied Neon panel
local APRON_Z = -23.5 -- D5: collidable house parts stay z >= this

local FLOORS_BY_TIER = table.freeze({ [0] = 0, [1] = 1, [2] = 2, [3] = 5 })

-- Budget envelope allowances (SOP §10 / plan D4).
local PARTS_PER_PODIUM = 3 -- plinth + Neon rarity ring + ShelfSlotPad pad
local VACANT_DRESSING_PART_ALLOWANCE = 20
local OWNER_SIGN_PART_ALLOWANCE = 10 -- D4: 6 -> 10 (6-part sign + anchor + trigger)

-- D3 footprints of record (T3 exactly at the 2-stud envelope, asserted below).
local FOOTPRINTS = table.freeze({
	[1] = table.freeze({ width = 33, depth = 30, frontZ = -14.5, backZ = 15.5 }),
	[2] = table.freeze({ width = 37, depth = 38, frontZ = -17, backZ = 21 }),
	[3] = table.freeze({ width = 41, depth = 45, frontZ = -19.5, backZ = 25.5 }),
})

-- §1.1-1.3 stair core rects (back-right, 13x14; mouth plane = minZ).
local CORE_RECTS = table.freeze({
	[1] = table.freeze({ minX = 2.5, maxX = 15.5, minZ = 0.5, maxZ = 14.5 }),
	[2] = table.freeze({ minX = 4.5, maxX = 17.5, minZ = 6, maxZ = 20 }),
	[3] = table.freeze({ minX = 6.5, maxX = 19.5, minZ = 10.5, maxZ = 24.5 }),
})

-- §3 gallery-loop podium tables (left row + back focal pair + right row +
-- 3 staggered islands = 12/floor; T1/T2 right rows tuned inside the binding
-- spacing/keep-clear envelope, T3 rows verbatim incl. the F5 setback variant).
local GALLERY = table.freeze({
	[1] = table.freeze({
		leftX = -12.5,
		leftZ = table.freeze({ -10, -4.5, 1, 6.5, 12 }),
		backZ = 11.5,
		backX = table.freeze({ -7, -2 }),
		rightX = 12.5,
		rightZ = table.freeze({ -12, -7 }),
		islands = table.freeze({ table.freeze({ 0, -8 }), table.freeze({ -5, -1 }), table.freeze({ -2.5, 5 }) }),
	}),
	[2] = table.freeze({
		leftX = -14.5,
		leftZ = table.freeze({ -12.5, -6, 0.5, 7, 13.5 }),
		backZ = 17,
		backX = table.freeze({ -10, -4 }),
		rightX = 14.5,
		rightZ = table.freeze({ -13, -7.5 }),
		islands = table.freeze({ table.freeze({ 0, -9 }), table.freeze({ -5, -2 }), table.freeze({ -1, 5 }) }),
	}),
	[3] = table.freeze({
		leftX = -16.5,
		leftZ = table.freeze({ -12, -4, 4, 12 }),
		backZ = 21.5,
		backX = table.freeze({ -14, -6 }),
		rightX = 16.5,
		rightZ = table.freeze({ -14, -7, 0 }),
		islands = table.freeze({ table.freeze({ 0, -10 }), table.freeze({ -4, -1 }), table.freeze({ 0, 8 }) }),
	}),
})
-- §3 T3 floor-5 penthouse setback variant (right row + islands shift with the
-- front wall; left row and back pair unchanged).
local GALLERY_T3_F5 = table.freeze({
	rightZ = table.freeze({ -11, -4.5, 2 }),
	islands = table.freeze({ table.freeze({ -4, 0 }), table.freeze({ 0, -8 }), table.freeze({ 0, 8 }) }),
})

-- Tier 0 grid: 2 rows x 4 columns at the 5-stud spacing of record, byte-
-- compatible with the pre-R5 plan (ShelfService specs depend on it).
local STARTER_COLUMN_X = table.freeze({
	-1.5 * PODIUM_SPACING,
	-0.5 * PODIUM_SPACING,
	0.5 * PODIUM_SPACING,
	1.5 * PODIUM_SPACING,
})
local STARTER_FRONT_ROW_Z = -8
local STARTER_ROW_Z = table.freeze({ STARTER_FRONT_ROW_Z, STARTER_FRONT_ROW_Z + PODIUM_SPACING })

-- Entry stairs (§1.1-1.3): thin inclined planks, NEVER full-height wedges.
-- T1 porch ramp rise 1 / run 4 (14 deg); T2/T3 stoops rise 3 / run 5 (31 deg).
local ENTRY = table.freeze({
	[1] = table.freeze({ width = 6, rise = 1, run = 4, lowZ = -21, thickness = 0.4 }),
	[2] = table.freeze({ width = 6, rise = 3, run = 5, lowZ = -22, thickness = 1 }),
	[3] = table.freeze({ width = 10, rise = 3, run = 5, lowZ = -22, thickness = 1 }),
})

--------------------------------------------------------------------------------
-- Internal helpers
--------------------------------------------------------------------------------

local function assertTier(tier: number)
	assert(
		type(tier) == "number" and tier % 1 == 0 and tier >= 0 and tier <= GameConstants.HOUSING_MAX_TIER,
		`HousePlan: tier must be an integer 0..{GameConstants.HOUSING_MAX_TIER}, got {tostring(tier)}`
	)
end

local function dim3(x: number, y: number, z: number): Dim3
	return table.freeze({ X = x, Y = y, Z = z })
end

local function box(sizeX: number, sizeY: number, sizeZ: number, x: number, y: number, z: number, color: RGB?): ShellPart
	return table.freeze({ size = dim3(sizeX, sizeY, sizeZ), offset = dim3(x, y, z), color = color })
end

-- Entry plank: same convention as HousePlanStairs.plank (D1 — the slope is
-- derived, never hand-typed; ascending toward +Z carries orientation.X < 0).
local function inclined(width: number, rise: number, run: number, lowZ: number, thickness: number): ShellPart
	local length = math.sqrt(run * run + rise * rise)
	local slope = math.deg(math.atan(rise / run))
	return table.freeze({
		size = dim3(width, thickness, length),
		offset = dim3(0, rise / 2, lowZ + run / 2),
		orientation = dim3(-slope, 0, 0),
	})
end

local function floorTopOf(tier: number, floorIndex: number): number
	return FFL1_BY_TIER[tier] + (floorIndex - 1) * FLOOR_PITCH -- D3 formula of record
end

local function slotCountForTier(tier: number): number
	if tier <= 0 then
		return GameConstants.SHELF_BASE_SLOTS
	end
	return GameConstants.HOUSING_TIER_SLOTS[tier]
end

local function makeSlot(index: number, label: string, x: number, y: number, z: number): SlotLayout
	return table.freeze({ slotId = `s{index}`, slotLabel = label, x = x, y = y, z = z })
end

-- §2.4 full-shaft L-cut: every slab above floor 1 (roof included) opens the
-- whole core rect as 2 rects — A spans the full width in front of the shaft,
-- B spans left of the shaft to the back. (The 1-stud strips left open over
-- the east/back wall bands sit directly above those walls.)
local function addCutSlabs(
	slabs: { ShellPart },
	minX: number,
	maxX: number,
	minZ: number,
	maxZ: number,
	top: number,
	cutout: Rect
)
	local y = top - SLAB_THICKNESS / 2
	slabs[#slabs + 1] =
		box(maxX - minX, SLAB_THICKNESS, cutout.minZ - minZ, (minX + maxX) / 2, y, (minZ + cutout.minZ) / 2)
	slabs[#slabs + 1] = box(
		cutout.minX - minX,
		SLAB_THICKNESS,
		maxZ - cutout.minZ,
		(minX + cutout.minX) / 2,
		y,
		(cutout.minZ + maxZ) / 2
	)
end

--------------------------------------------------------------------------------
-- Footprints (D3 + D6 heights)
--------------------------------------------------------------------------------

local footprintCache: { [number]: Footprint } = {}

local function footprintOf(tier: number): Footprint
	local cached = footprintCache[tier]
	if cached ~= nil then
		return cached
	end
	local base = FOOTPRINTS[tier]
	assert(base ~= nil, `HousePlan: no footprint of record for tier {tier}`)
	local roofTop = FFL1_BY_TIER[tier] + FLOORS_BY_TIER[tier] * FLOOR_PITCH -- D6: 11 / 23 / 53
	local footprint: Footprint = table.freeze({
		width = base.width,
		depth = base.depth,
		centerZ = (base.frontZ + base.backZ) / 2,
		frontZ = base.frontZ,
		backZ = base.backZ,
		ffl1 = FFL1_BY_TIER[tier],
		roofTop = roofTop,
		parapetTop = roofTop + PARAPET_HEIGHT,
		bulkheadTop = roofTop + StairCore.BULKHEAD_WALL_HEIGHT_STUDS + 1, -- D6: 20 / 32 / 62
	})
	footprintCache[tier] = footprint
	return footprint
end

--------------------------------------------------------------------------------
-- Stair core composition (one Generate per tier, memoized)
--------------------------------------------------------------------------------

local stairCoreCache: { [number]: StairCore.StairCoreResult } = {}

local function stairCoreOf(tier: number): StairCore.StairCoreResult
	local cached = stairCoreCache[tier]
	if cached ~= nil then
		return cached
	end
	local core = CORE_RECTS[tier]
	local accents: { RGB } = if tier == 3 then PALETTE.T3_FLOOR_ACCENTS else { PALETTE.TIER_IDENTITY[tier] }
	local result = StairCore.Generate({
		coreMinX = core.minX,
		coreMaxX = core.maxX,
		coreMinZ = core.minZ,
		coreMaxZ = core.maxZ,
		mouthZ = core.minZ,
		ffl1 = FFL1_BY_TIER[tier],
		floors = FLOORS_BY_TIER[tier],
		pitch = FLOOR_PITCH,
		accentColors = accents,
	})
	stairCoreCache[tier] = result
	return result
end

--------------------------------------------------------------------------------
-- Podium layouts (§3 gallery loop)
--------------------------------------------------------------------------------

local function buildStarterLayouts(): { SlotLayout }
	local layouts: { SlotLayout } = {}
	for _, z in STARTER_ROW_Z do
		for _, x in STARTER_COLUMN_X do
			table.insert(layouts, makeSlot(#layouts + 1, `Podium {#layouts + 1}`, x, 0, z))
		end
	end
	return layouts
end

local function gallerySpots(tier: number, floorIndex: number): { { number } }
	local zone = GALLERY[tier]
	local setback = tier == 3 and floorIndex == 5
	local rightZ = if setback then GALLERY_T3_F5.rightZ else zone.rightZ
	local islands = if setback then GALLERY_T3_F5.islands else zone.islands
	local spots: { { number } } = {}
	for _, z in zone.leftZ do
		table.insert(spots, { zone.leftX, z })
	end
	for _, x in zone.backX do
		table.insert(spots, { x, zone.backZ })
	end
	for _, z in rightZ do
		table.insert(spots, { zone.rightX, z })
	end
	for _, island in islands do
		table.insert(spots, { island[1], island[2] })
	end
	-- D7 ordering of record: per floor z ascending, then x ascending.
	table.sort(spots, function(a, b)
		if a[2] ~= b[2] then
			return a[2] < b[2]
		end
		return a[1] < b[1]
	end)
	return spots
end

local function buildLayouts(tier: number): { SlotLayout }
	if tier <= 0 then
		return buildStarterLayouts()
	end
	local floors = FLOORS_BY_TIER[tier]
	local layouts: { SlotLayout } = {}
	for floorIndex = 1, floors do
		local label = if floors == 1 then "House" else `Floor {floorIndex}`
		local y = floorTopOf(tier, floorIndex)
		for spotIndex, spot in gallerySpots(tier, floorIndex) do
			table.insert(layouts, makeSlot(#layouts + 1, `{label} Slot {spotIndex}`, spot[1], y, spot[2]))
		end
	end
	return layouts
end

--------------------------------------------------------------------------------
-- Shared massing pieces
--------------------------------------------------------------------------------

-- Per-storey perimeter walls; floor 1 front gets the 7x7 door split. The
-- front wall plane may differ from the footprint front (T3 portico recess).
local function addSideAndBackWalls(walls: { ShellPart }, tier: number, top: number, bottomOverride: number?)
	local footprint = footprintOf(tier)
	local halfW = footprint.width / 2
	local bottom = if bottomOverride ~= nil then bottomOverride else top
	local height = top + WALL_HEIGHT - bottom
	local y = bottom + height / 2
	walls[#walls + 1] = box(WALL_THICKNESS, height, footprint.depth, -(halfW - 0.5), y, footprint.centerZ)
	walls[#walls + 1] = box(WALL_THICKNESS, height, footprint.depth, halfW - 0.5, y, footprint.centerZ)
	walls[#walls + 1] = box(
		footprint.width - 2 * WALL_THICKNESS,
		top + WALL_HEIGHT - top,
		WALL_THICKNESS,
		0,
		top + WALL_HEIGHT / 2,
		footprint.backZ - 0.5
	)
end

-- Front wall plate with a centered door opening: two segments + header.
local function addDoorWall(
	walls: { ShellPart },
	innerWidth: number,
	wallZ: number,
	top: number,
	doorWidth: number,
	doorHeight: number
)
	local segmentWidth = (innerWidth - doorWidth) / 2
	local segmentX = doorWidth / 2 + segmentWidth / 2
	local y = top + WALL_HEIGHT / 2
	walls[#walls + 1] = box(segmentWidth, WALL_HEIGHT, WALL_THICKNESS, -segmentX, y, wallZ)
	walls[#walls + 1] = box(segmentWidth, WALL_HEIGHT, WALL_THICKNESS, segmentX, y, wallZ)
	walls[#walls + 1] = box(
		doorWidth,
		WALL_HEIGHT - doorHeight,
		WALL_THICKNESS,
		0,
		top + doorHeight + (WALL_HEIGHT - doorHeight) / 2,
		wallZ
	)
end

-- §4 parapet ring + tier-identity Neon cap on the street run.
local function addParapet(
	walls: { ShellPart },
	neon: { ShellPart },
	tier: number,
	frontZ: number,
	backZ: number,
	width: number
)
	local footprint = footprintOf(tier)
	local halfW = width / 2
	local y = footprint.roofTop + PARAPET_HEIGHT / 2
	walls[#walls + 1] = box(width, PARAPET_HEIGHT, WALL_THICKNESS, 0, y, frontZ + 0.5)
	walls[#walls + 1] = box(width, PARAPET_HEIGHT, WALL_THICKNESS, 0, y, backZ - 0.5)
	walls[#walls + 1] = box(WALL_THICKNESS, PARAPET_HEIGHT, backZ - frontZ - 2, -(halfW - 0.5), y, (frontZ + backZ) / 2)
	walls[#walls + 1] = box(WALL_THICKNESS, PARAPET_HEIGHT, backZ - frontZ - 2, halfW - 0.5, y, (frontZ + backZ) / 2)
	neon[#neon + 1] = box(width - 2, 0.3, 1, 0, footprint.parapetTop + 0.15, frontZ + 0.5, PALETTE.TIER_IDENTITY[tier])
end

-- §1.0 entry emphasis: Neon door surround (2 jambs + lintel) on the door
-- wall's street face. Gold for T3 (§1.3), tier identity otherwise.
local function addDoorSurround(neon: { ShellPart }, tier: number, doorWallZ: number, top: number, doorWidth: number)
	local color = if tier == 3 then PALETTE.GOLD else PALETTE.TIER_IDENTITY[tier]
	local faceZ = doorWallZ - 0.5 - 0.15
	local jambX = doorWidth / 2 + 0.15
	neon[#neon + 1] = box(0.3, DOOR_HEIGHT, 0.3, -jambX, top + DOOR_HEIGHT / 2, faceZ, color)
	neon[#neon + 1] = box(0.3, DOOR_HEIGHT, 0.3, jambX, top + DOOR_HEIGHT / 2, faceZ, color)
	local lintelWidth = if tier == 3 then 8 else doorWidth + 0.6 -- T3: oversized gold lintel (§1.3)
	local lintelHeight = if tier == 3 then 1 else 0.6
	neon[#neon + 1] = box(lintelWidth, lintelHeight, 0.3, 0, top + DOOR_HEIGHT + lintelHeight / 2 + 0.1, faceZ, color)
end

-- §3 interior Neon per floor: backwall strip + cove strip + 2x2 floor sign
-- at the core mouth. T3 takes the per-floor wayfinding accents.
local function addInteriorNeon(neon: { ShellPart }, tier: number, floorIndex: number)
	local footprint = footprintOf(tier)
	local core = CORE_RECTS[tier]
	local top = floorTopOf(tier, floorIndex)
	local accent: RGB? = if tier == 3 then PALETTE.T3_FLOOR_ACCENTS[floorIndex] else nil
	local backFace = footprint.backZ - WALL_THICKNESS
	local backX = (GALLERY[tier].backX[1] + GALLERY[tier].backX[2]) / 2
	neon[#neon + 1] = box(6, 1, 0.3, backX, top + 1.3, backFace - 0.15, accent)
	neon[#neon + 1] = box(4, 0.3, 0.3, -8, top + WALL_HEIGHT - 0.5, footprint.centerZ, accent)
	neon[#neon + 1] = box(2, 2, 0.3, (core.minX + core.maxX) / 2, top + WALL_HEIGHT - 1, core.minZ - 0.35, accent)
end

local function mergeFrom(target: { ShellPart }, source: { ShellPart })
	for _, entry in source do
		target[#target + 1] = entry
	end
end

--------------------------------------------------------------------------------
-- Tier massing (§1.1 / §1.2 / §1.3 / §4)
--------------------------------------------------------------------------------

local function buildTier1(shell: Shell)
	local tier = 1
	local footprint = footprintOf(tier)
	local core = CORE_RECTS[tier]
	local top = footprint.ffl1 -- 1
	local walls, slabs, stairs, windows, neon = shell.walls, shell.slabs, shell.stairs, shell.windows, shell.neon

	-- Ground slab: ONE plate of thickness == FFL1 (D3).
	slabs[#slabs + 1] = box(footprint.width, footprint.ffl1, footprint.depth, 0, footprint.ffl1 / 2, footprint.centerZ)

	addSideAndBackWalls(walls, tier, top)
	addDoorWall(walls, footprint.width - 2, footprint.frontZ + 0.5, top, DOOR_WIDTH, DOOR_HEIGHT)
	addDoorSurround(neon, tier, footprint.frontZ + 0.5, top, DOOR_WIDTH)

	-- Roof (full-shaft L-cut, §2.4) + parapet + amber cap.
	addCutSlabs(
		slabs,
		-footprint.width / 2,
		footprint.width / 2,
		footprint.frontZ,
		footprint.backZ,
		footprint.roofTop,
		{
			minX = core.minX,
			maxX = core.maxX,
			minZ = core.minZ,
			maxZ = core.maxZ,
		}
	)
	addParapet(walls, neon, tier, footprint.frontZ, footprint.backZ, footprint.width)

	-- Depth-rule kit (§1.0): pilasters + plinth band on the street face.
	walls[#walls + 1] = box(1, footprint.roofTop, 1, -13, footprint.roofTop / 2, footprint.frontZ - 0.5)
	walls[#walls + 1] = box(1, footprint.roofTop, 1, 13, footprint.roofTop / 2, footprint.frontZ - 0.5)
	-- Plinth band splits around the 7-wide entry (R5 walk-test fix: a full-width
	-- 2.5-tall band across the doorway is unsteppable and kills pathfinding).
	local plinthSegmentWidth = (footprint.width - DOOR_WIDTH) / 2
	local plinthSegmentX = (footprint.width + DOOR_WIDTH) / 4
	walls[#walls + 1] = box(plinthSegmentWidth, 2.5, 1, -plinthSegmentX, 1.25, footprint.frontZ - 0.5, PALETTE.SLATE)
	walls[#walls + 1] = box(plinthSegmentWidth, 2.5, 1, plinthSegmentX, 1.25, footprint.frontZ - 0.5, PALETTE.SLATE)

	-- Entry: porch slab + flat awning on two columns + 14-deg ramp plank.
	slabs[#slabs + 1] = box(6, 1, 2.5, 0, 0.5, -15.75)
	slabs[#slabs + 1] = box(8, 0.4, 4, 0, 8.7, -16.5)
	walls[#walls + 1] = box(0.6, 7.5, 0.6, -2.6, 4.75, -16.5)
	walls[#walls + 1] = box(0.6, 7.5, 0.6, 2.6, 4.75, -16.5)
	local entry = ENTRY[tier]
	stairs[#stairs + 1] = inclined(entry.width, entry.rise, entry.run, entry.lowZ, entry.thickness)

	-- Facade glazing: 3 showcase panels (3x6) + side/back standard panels.
	local frontFaceZ = footprint.frontZ - WINDOW_THICKNESS / 2
	for _, x in { -10, -6, 9 } do
		windows[#windows + 1] = box(3, 6, WINDOW_THICKNESS, x, top + 3.5, frontFaceZ)
	end
	local sideFaceX = footprint.width / 2 + WINDOW_THICKNESS / 2
	for _, z in { -5, 5 } do
		windows[#windows + 1] = box(WINDOW_THICKNESS, 4, 3, -sideFaceX, top + 4.5, z)
		windows[#windows + 1] = box(WINDOW_THICKNESS, 4, 3, sideFaceX, top + 4.5, z)
	end
	for _, x in { -6, 6 } do
		windows[#windows + 1] = box(3, 4, WINDOW_THICKNESS, x, top + 4.5, footprint.backZ + WINDOW_THICKNESS / 2)
	end

	-- Front yard (§1.1): path + amber edge strips + ground dots + low fence;
	-- carport wing on the right (slab on two columns).
	slabs[#slabs + 1] = box(4, 0.15, 9, 0, 0.075, -19)
	neon[#neon + 1] = box(0.3, 0.15, 9, -2.15, 0.075, -19, PALETTE.TIER_IDENTITY[tier])
	neon[#neon + 1] = box(0.3, 0.15, 9, 2.15, 0.075, -19, PALETTE.TIER_IDENTITY[tier])
	neon[#neon + 1] = box(2, 0.1, 2, 3, 0.05, -18, PALETTE.TIER_IDENTITY[tier])
	neon[#neon + 1] = box(2, 0.1, 2, -3, 0.05, -21, PALETTE.TIER_IDENTITY[tier])
	walls[#walls + 1] = box(8, 1.2, 0.3, -13, 0.6, -23.2)
	walls[#walls + 1] = box(8, 1.2, 0.3, 13, 0.6, -23.2)
	slabs[#slabs + 1] = box(10, 0.4, 8, 11.5, 8.2, -19)
	walls[#walls + 1] = box(1, 8, 1, 15.5, 4, -22)
	walls[#walls + 1] = box(1, 8, 1, 15.5, 4, -16)

	-- Roof terrace decor (§4 T1): string-light post + bench + grill.
	walls[#walls + 1] = box(0.4, 3, 0.4, -10, footprint.roofTop + 1.5, 8)
	neon[#neon + 1] = box(2, 0.3, 0.3, -10, footprint.roofTop + 3.15, 8, PALETTE.T3_FLOOR_ACCENTS[6])
	walls[#walls + 1] = box(3, 1, 1, -10, footprint.roofTop + 0.5, 12)
	walls[#walls + 1] = box(1.5, 2, 1, -12, footprint.roofTop + 1, -8)

	addInteriorNeon(neon, tier, 1)
end

local function buildTier2(shell: Shell)
	local tier = 2
	local footprint = footprintOf(tier)
	local core = CORE_RECTS[tier]
	local halfW = footprint.width / 2
	local walls, slabs, stairs, windows, neon = shell.walls, shell.slabs, shell.stairs, shell.windows, shell.neon
	local cutout: Rect = { minX = core.minX, maxX = core.maxX, minZ = core.minZ, maxZ = core.maxZ }
	local identity = PALETTE.TIER_IDENTITY[tier]

	slabs[#slabs + 1] = box(footprint.width, footprint.ffl1, footprint.depth, 0, footprint.ffl1 / 2, footprint.centerZ)

	for floorIndex = 1, 2 do
		local top = floorTopOf(tier, floorIndex)
		addSideAndBackWalls(walls, tier, top)
		if floorIndex == 1 then
			addDoorWall(walls, footprint.width - 2, footprint.frontZ + 0.5, top, DOOR_WIDTH, DOOR_HEIGHT)
		else
			walls[#walls + 1] =
				box(footprint.width - 2, WALL_HEIGHT, WALL_THICKNESS, 0, top + WALL_HEIGHT / 2, footprint.frontZ + 0.5)
			addCutSlabs(slabs, -halfW, halfW, footprint.frontZ, footprint.backZ, top, cutout)
		end
		addInteriorNeon(neon, tier, floorIndex)
	end
	addDoorSurround(neon, tier, footprint.frontZ + 0.5, footprint.ffl1, DOOR_WIDTH)

	addCutSlabs(slabs, -halfW, halfW, footprint.frontZ, footprint.backZ, footprint.roofTop, cutout)
	addParapet(walls, neon, tier, footprint.frontZ, footprint.backZ, footprint.width)
	-- §1.2 corner piers on the parapet.
	for _, x in { -(halfW - 0.75), halfW - 0.75 } do
		for _, z in { footprint.frontZ + 0.75, footprint.backZ - 0.75 } do
			walls[#walls + 1] = box(1.5, 5, 1.5, x, footprint.roofTop + 2.5, z)
		end
	end

	-- §1.2 brownstone stoop: 31-deg plank + cheek walls + cyan cheek caps.
	local entry = ENTRY[tier]
	stairs[#stairs + 1] = inclined(entry.width, entry.rise, entry.run, entry.lowZ, entry.thickness)
	walls[#walls + 1] = box(1, 3.5, 5, -3.5, 1.75, -19.5)
	walls[#walls + 1] = box(1, 3.5, 5, 3.5, 1.75, -19.5)
	neon[#neon + 1] = box(1, 0.3, 5, -3.5, 3.65, -19.5, identity)
	neon[#neon + 1] = box(1, 0.3, 5, 3.5, 3.65, -19.5, identity)

	-- Balcony-over-door (decorative): slab + 3-high rail + cyan cap.
	slabs[#slabs + 1] = box(8, 0.4, 1.4, 0, floorTopOf(tier, 2) - 0.2, -17.6)
	walls[#walls + 1] = box(8, GUARD_HEIGHT, 0.3, 0, floorTopOf(tier, 2) + 1.5, -18.15)
	walls[#walls + 1] = box(0.3, GUARD_HEIGHT, 1.4, -3.85, floorTopOf(tier, 2) + 1.5, -17.6)
	walls[#walls + 1] = box(0.3, GUARD_HEIGHT, 1.4, 3.85, floorTopOf(tier, 2) + 1.5, -17.6)
	neon[#neon + 1] = box(8, 0.3, 0.3, 0, floorTopOf(tier, 2) + 3.15, -18.15, identity)

	-- 2-proud bay window through both floors (front-left) + trim band +
	-- pilasters + plinth band (§1.0 depth rule).
	walls[#walls + 1] = box(8, 20, 2, -13.5, 13, -18)
	walls[#walls + 1] = box(footprint.width, 1, 0.5, 0, floorTopOf(tier, 2), footprint.frontZ - 0.25)
	walls[#walls + 1] = box(1, 20, 1, -16.5, 13, footprint.frontZ - 0.5)
	walls[#walls + 1] = box(1, 20, 1, 16.5, 13, footprint.frontZ - 0.5)
	-- Plinth band splits around the 7-wide entry (R5 walk-test fix: a full-width
	-- 2.5-tall band across the doorway is unsteppable and kills pathfinding).
	local plinthSegmentWidth = (footprint.width - DOOR_WIDTH) / 2
	local plinthSegmentX = (footprint.width + DOOR_WIDTH) / 4
	walls[#walls + 1] = box(plinthSegmentWidth, 2.5, 1, -plinthSegmentX, 1.25, footprint.frontZ - 0.5, PALETTE.SLATE)
	walls[#walls + 1] = box(plinthSegmentWidth, 2.5, 1, plinthSegmentX, 1.25, footprint.frontZ - 0.5, PALETTE.SLATE)

	-- Glazing: ground showcase + floor-2 rhythm + bay panels + sides/back.
	local frontFaceZ = footprint.frontZ - WINDOW_THICKNESS / 2
	for _, x in { 7.5, 13.5 } do
		windows[#windows + 1] = box(3, 6, WINDOW_THICKNESS, x, footprint.ffl1 + 3.5, frontFaceZ)
	end
	for _, x in { -3, 3, 9, 14 } do
		windows[#windows + 1] = box(3, 4, WINDOW_THICKNESS, x, floorTopOf(tier, 2) + 4.5, frontFaceZ)
	end
	for _, x in { -15.5, -11.5 } do
		windows[#windows + 1] = box(3, 4, WINDOW_THICKNESS, x, footprint.ffl1 + 3.5, -19 - WINDOW_THICKNESS / 2)
	end
	local sideFaceX = halfW + WINDOW_THICKNESS / 2
	for floorIndex = 1, 2 do
		local y = floorTopOf(tier, floorIndex) + 4.5
		for _, z in { -5, 5 } do
			windows[#windows + 1] = box(WINDOW_THICKNESS, 4, 3, -sideFaceX, y, z)
			windows[#windows + 1] = box(WINDOW_THICKNESS, 4, 3, sideFaceX, y, z)
		end
		for _, x in { -6, 6 } do
			windows[#windows + 1] = box(3, 4, WINDOW_THICKNESS, x, y, footprint.backZ + WINDOW_THICKNESS / 2)
		end
	end

	-- Yard (§1.2): driveway (stops at the apron line) + hedge runs.
	slabs[#slabs + 1] = box(8, 0.3, 6.5, 14, 0.15, -20.25)
	walls[#walls + 1] = box(0.5, 2, 38.5, -21, 1, -4.25)
	walls[#walls + 1] = box(0.5, 2, 38.5, 21, 1, -4.25)

	-- Roof terrace decor (§4 T2): two posts + Neon string + bench cluster.
	walls[#walls + 1] = box(0.4, 3, 0.4, -12, footprint.roofTop + 1.5, 0)
	walls[#walls + 1] = box(0.4, 3, 0.4, -12, footprint.roofTop + 1.5, 8)
	neon[#neon + 1] = box(0.2, 0.2, 8, -12, footprint.roofTop + 3.1, 4, PALETTE.T3_FLOOR_ACCENTS[6])
	walls[#walls + 1] = box(3, 1, 1, -14, footprint.roofTop + 0.5, -9)
	walls[#walls + 1] = box(1, 1, 1, -14, footprint.roofTop + 0.5, -11)
end

local function buildTier3(shell: Shell)
	local tier = 3
	local footprint = footprintOf(tier)
	local core = CORE_RECTS[tier]
	local halfW = footprint.width / 2
	local walls, slabs, stairs, windows, neon = shell.walls, shell.slabs, shell.stairs, shell.windows, shell.neon
	local cutout: Rect = { minX = core.minX, maxX = core.maxX, minZ = core.minZ, maxZ = core.maxZ }
	local identity = PALETTE.TIER_IDENTITY[tier]
	local gradient = PALETTE.T3_WINDOW_GRADIENT

	-- §1.3 portico recess: the door bay (10 wide) of floors 1-2 steps back to
	-- the recessed plane; interior slabs are never cut for the portico. The
	-- ground slab starts at the recessed plane so the grand stoop lands flush.
	local PORTICO_WIDTH = 10
	local RECESSED_WALL_Z = -16.5 -- wall center; door face z -17
	local setbackTop = floorTopOf(tier, 5)

	slabs[#slabs + 1] = box(
		footprint.width,
		footprint.ffl1,
		footprint.backZ - (RECESSED_WALL_Z - 0.5),
		0,
		footprint.ffl1 / 2,
		(RECESSED_WALL_Z - 0.5 + footprint.backZ) / 2
	)

	for floorIndex = 1, 5 do
		local top = floorTopOf(tier, floorIndex)
		if floorIndex == 1 then
			-- Floor 1 walls drop to the pad (the slab starts at the recess).
			addSideAndBackWalls(walls, tier, top, 0)
			local outerSegment = (footprint.width - 2 - PORTICO_WIDTH) / 2 -- 14.5
			local outerX = PORTICO_WIDTH / 2 + outerSegment / 2 -- 12.25
			local outerHeight = top + WALL_HEIGHT
			walls[#walls + 1] = box(outerSegment, outerHeight, 1, -outerX, outerHeight / 2, footprint.frontZ + 0.5)
			walls[#walls + 1] = box(outerSegment, outerHeight, 1, outerX, outerHeight / 2, footprint.frontZ + 0.5)
			-- Portico side returns connect the front plane to the recess.
			walls[#walls + 1] = box(1, outerHeight, 2.5, -5.5, outerHeight / 2, -18.25)
			walls[#walls + 1] = box(1, outerHeight, 2.5, 5.5, outerHeight / 2, -18.25)
			addDoorWall(walls, PORTICO_WIDTH, RECESSED_WALL_Z, top, DOOR_WIDTH, DOOR_HEIGHT)
		elseif floorIndex == 2 then
			addSideAndBackWalls(walls, tier, top)
			local outerSegment = (footprint.width - 2 - PORTICO_WIDTH) / 2
			local outerX = PORTICO_WIDTH / 2 + outerSegment / 2
			walls[#walls + 1] =
				box(outerSegment, WALL_HEIGHT, 1, -outerX, top + WALL_HEIGHT / 2, footprint.frontZ + 0.5)
			walls[#walls + 1] = box(outerSegment, WALL_HEIGHT, 1, outerX, top + WALL_HEIGHT / 2, footprint.frontZ + 0.5)
			walls[#walls + 1] = box(1, WALL_HEIGHT, 2.5, -5.5, top + WALL_HEIGHT / 2, -18.25)
			walls[#walls + 1] = box(1, WALL_HEIGHT, 2.5, 5.5, top + WALL_HEIGHT / 2, -18.25)
			walls[#walls + 1] = box(PORTICO_WIDTH, WALL_HEIGHT, 1, 0, top + WALL_HEIGHT / 2, RECESSED_WALL_Z)
		elseif floorIndex <= 4 then
			addSideAndBackWalls(walls, tier, top)
			walls[#walls + 1] =
				box(footprint.width - 2, WALL_HEIGHT, 1, 0, top + WALL_HEIGHT / 2, footprint.frontZ + 0.5)
		else
			-- §1.3 floor-5 penthouse setback: front wall back 4 studs with the
			-- 6x7 terrace door; side walls stop at the setback plane.
			local setbackFrontZ = footprint.frontZ + 4 -- -15.5
			walls[#walls + 1] = box(
				1,
				WALL_HEIGHT,
				footprint.backZ - setbackFrontZ,
				-(halfW - 0.5),
				top + WALL_HEIGHT / 2,
				(setbackFrontZ + footprint.backZ) / 2
			)
			walls[#walls + 1] = box(
				1,
				WALL_HEIGHT,
				footprint.backZ - setbackFrontZ,
				halfW - 0.5,
				top + WALL_HEIGHT / 2,
				(setbackFrontZ + footprint.backZ) / 2
			)
			walls[#walls + 1] =
				box(footprint.width - 2, WALL_HEIGHT, 1, 0, top + WALL_HEIGHT / 2, footprint.backZ - 0.5)
			addDoorWall(walls, footprint.width - 2, setbackFrontZ + 0.5, top, TERRACE_DOOR_WIDTH, DOOR_HEIGHT)
		end
		if floorIndex >= 2 then
			addCutSlabs(slabs, -halfW, halfW, footprint.frontZ, footprint.backZ, top, cutout)
		end
		addInteriorNeon(neon, tier, floorIndex)
	end
	addDoorSurround(neon, tier, RECESSED_WALL_Z, footprint.ffl1, DOOR_WIDTH)

	-- Roof over the setback massing + parapet + magenta cap.
	local roofFrontZ = footprint.frontZ + 4
	addCutSlabs(slabs, -halfW, halfW, roofFrontZ, footprint.backZ, footprint.roofTop, cutout)
	addParapet(walls, neon, tier, roofFrontZ, footprint.backZ, footprint.width)

	-- §1.3 F4 front terrace (41 x 4 exposed strip at floor-5 level): 3-high
	-- rail + magenta Neon cap on the open edges.
	walls[#walls + 1] = box(footprint.width, GUARD_HEIGHT, 1, 0, setbackTop + GUARD_HEIGHT / 2, footprint.frontZ + 0.5)
	walls[#walls + 1] = box(1, GUARD_HEIGHT, 3, -(halfW - 0.5), setbackTop + GUARD_HEIGHT / 2, -17)
	walls[#walls + 1] = box(1, GUARD_HEIGHT, 3, halfW - 0.5, setbackTop + GUARD_HEIGHT / 2, -17)
	neon[#neon + 1] =
		box(footprint.width, 0.3, 1, 0, setbackTop + GUARD_HEIGHT + 0.15, footprint.frontZ + 0.5, identity)

	-- Double-height portico columns (through floors 1-2, standing on the pad)
	-- + pilasters + plinth band (§1.0 depth rule).
	walls[#walls + 1] = box(1.5, 23, 1.5, -4.5, 11.5, -18.75)
	walls[#walls + 1] = box(1.5, 23, 1.5, 4.5, 11.5, -18.75)
	for _, x in { -18, -6, 6, 18 } do
		walls[#walls + 1] = box(1, 43, 1, x, 21.5, footprint.frontZ - 0.5)
	end
	-- Plinth band splits around the 7-wide entry (R5 walk-test fix: a full-width
	-- 2.5-tall band across the doorway is unsteppable and kills pathfinding).
	local plinthSegmentWidth = (footprint.width - DOOR_WIDTH) / 2
	local plinthSegmentX = (footprint.width + DOOR_WIDTH) / 4
	walls[#walls + 1] = box(plinthSegmentWidth, 2.5, 1, -plinthSegmentX, 1.25, footprint.frontZ - 0.5, PALETTE.SLATE)
	walls[#walls + 1] = box(plinthSegmentWidth, 2.5, 1, plinthSegmentX, 1.25, footprint.frontZ - 0.5, PALETTE.SLATE)

	-- Grand entry stair (10 wide, 31 deg) landing flush at the recessed door.
	local entry = ENTRY[tier]
	stairs[#stairs + 1] = inclined(entry.width, entry.rise, entry.run, entry.lowZ, entry.thickness)

	-- §1.3 Juliet balconies floors 2-4 (slab + Neon rail, aligned at x 0).
	for floorIndex = 2, 4 do
		local top = floorTopOf(tier, floorIndex)
		slabs[#slabs + 1] = box(10, 0.3, 1.5, 0, top + 0.15, -20.25)
		neon[#neon + 1] = box(10, 0.3, 0.3, 0, top + 1.15, -20.85, identity)
	end

	-- §1.3 full-height Neon blade at the stair core's exterior corner — the
	-- tallest light on the street, under the 60-stud queue beacon (D6).
	neon[#neon + 1] = box(0.5, 50, 0.5, 20.25, 25, 25.25, identity)

	-- Glazing: warm->cool gradient by floor (§1.3); back panels applied on
	-- the interior face (the lot edge band is tighter than the panel reach).
	for floorIndex = 1, 5 do
		local top = floorTopOf(tier, floorIndex)
		local color = gradient[floorIndex]
		if floorIndex <= 2 then
			for _, x in { -12, 12 } do
				windows[#windows + 1] =
					box(3, 4, WINDOW_THICKNESS, x, top + 4.5, footprint.frontZ - WINDOW_THICKNESS / 2, color)
			end
		elseif floorIndex <= 4 then
			for _, x in { -15, -9, 9, 15 } do
				windows[#windows + 1] =
					box(3, 4, WINDOW_THICKNESS, x, top + 4.5, footprint.frontZ - WINDOW_THICKNESS / 2, color)
			end
		else
			for _, x in { -9, 9 } do
				windows[#windows + 1] =
					box(3, 4, WINDOW_THICKNESS, x, top + 4.5, footprint.frontZ + 4 - WINDOW_THICKNESS / 2, color)
			end
		end
		-- Side panels apply on the INTERIOR wall face: T3 sits exactly at the
		-- 2-stud envelope, so an exterior-proud panel would breach it (D5).
		local sideFaceX = halfW - WALL_THICKNESS - WINDOW_THICKNESS / 2
		for _, z in { -5, 5 } do
			windows[#windows + 1] = box(WINDOW_THICKNESS, 4, 3, -sideFaceX, top + 4.5, z, color)
			windows[#windows + 1] = box(WINDOW_THICKNESS, 4, 3, sideFaceX, top + 4.5, z, color)
		end
		for _, x in { -10, -2 } do
			windows[#windows + 1] =
				box(3, 4, WINDOW_THICKNESS, x, top + 4.5, footprint.backZ - 1 - WINDOW_THICKNESS / 2, color)
		end
	end

	-- Roof terrace decor (§4 T3): lounge cluster + helipad motif (disc +
	-- high-V Neon ring + cone with a Neon tip disc — zero Lights) + spire.
	walls[#walls + 1] = box(3, 1, 1, -12, footprint.roofTop + 0.5, 6)
	walls[#walls + 1] = box(3, 1, 1, -12, footprint.roofTop + 0.5, 9)
	walls[#walls + 1] = box(1.5, 1.5, 1.5, -15, footprint.roofTop + 0.75, 7.5)
	slabs[#slabs + 1] = box(8, 0.3, 8, 0, footprint.roofTop + 0.15, -3.5)
	neon[#neon + 1] = box(9.2, 0.3, 0.6, 0, footprint.roofTop + 0.3, 0.8, identity)
	neon[#neon + 1] = box(9.2, 0.3, 0.6, 0, footprint.roofTop + 0.3, -7.8, identity)
	neon[#neon + 1] = box(0.6, 0.3, 8, 4.3, footprint.roofTop + 0.3, -3.5, identity)
	neon[#neon + 1] = box(0.6, 0.3, 8, -4.3, footprint.roofTop + 0.3, -3.5, identity)
	walls[#walls + 1] = box(1.2, 2, 1.2, 5, footprint.roofTop + 1, 1.5)
	neon[#neon + 1] = box(1, 0.2, 1, 5, footprint.roofTop + 2.1, 1.5, identity)
	-- §2.5 skyline spire on the bulkhead cap (<= 2 studs, D6).
	neon[#neon + 1] =
		box(0.5, 2, 0.5, (core.minX + core.maxX) / 2, footprint.bulkheadTop + 1, (core.minZ + core.maxZ) / 2, identity)
end

--------------------------------------------------------------------------------
-- Shell assembly
--------------------------------------------------------------------------------

local function buildShell(tier: number): Shell
	local floors = FLOORS_BY_TIER[tier]
	local shell: Shell = {
		floors = floors,
		walls = {},
		slabs = {},
		stairs = {},
		windows = {},
		neon = {},
	}
	if floors == 0 then
		return table.freeze({
			floors = 0,
			walls = table.freeze(shell.walls),
			slabs = table.freeze(shell.slabs),
			stairs = table.freeze(shell.stairs),
			windows = table.freeze(shell.windows),
			neon = table.freeze(shell.neon),
		})
	end

	if tier == 1 then
		buildTier1(shell)
	elseif tier == 2 then
		buildTier2(shell)
	else
		buildTier3(shell)
	end

	-- Compose the §2 stair core (planks/landings/spine/enclosure/bulkhead).
	local core = stairCoreOf(tier)
	mergeFrom(shell.stairs, core.stairs)
	mergeFrom(shell.walls, core.walls)
	mergeFrom(shell.slabs, core.slabs)
	mergeFrom(shell.neon, core.neon)

	return table.freeze({
		floors = floors,
		walls = table.freeze(shell.walls),
		slabs = table.freeze(shell.slabs),
		stairs = table.freeze(shell.stairs),
		windows = table.freeze(shell.windows),
		neon = table.freeze(shell.neon),
	})
end

-- Ghost preview plan (D2/§5): exterior walls + parapet + roof slabs +
-- bulkhead ONLY — nesting (asserted below) keeps every plane off the built
-- tier's planes.
local function buildGhost(tier: number): { ShellPart }
	local parts: { ShellPart } = {}
	if FLOORS_BY_TIER[tier] == 0 then
		return table.freeze(parts)
	end
	local footprint = footprintOf(tier)
	local core = CORE_RECTS[tier]
	local halfW = footprint.width / 2
	local height = footprint.roofTop
	parts[#parts + 1] = box(WALL_THICKNESS, height, footprint.depth, -(halfW - 0.5), height / 2, footprint.centerZ)
	parts[#parts + 1] = box(WALL_THICKNESS, height, footprint.depth, halfW - 0.5, height / 2, footprint.centerZ)
	parts[#parts + 1] = box(footprint.width - 2, height, WALL_THICKNESS, 0, height / 2, footprint.frontZ + 0.5)
	parts[#parts + 1] = box(footprint.width - 2, height, WALL_THICKNESS, 0, height / 2, footprint.backZ - 0.5)
	local parapetY = footprint.roofTop + PARAPET_HEIGHT / 2
	parts[#parts + 1] = box(footprint.width, PARAPET_HEIGHT, WALL_THICKNESS, 0, parapetY, footprint.frontZ + 0.5)
	parts[#parts + 1] = box(footprint.width, PARAPET_HEIGHT, WALL_THICKNESS, 0, parapetY, footprint.backZ - 0.5)
	parts[#parts + 1] =
		box(WALL_THICKNESS, PARAPET_HEIGHT, footprint.depth - 2, -(halfW - 0.5), parapetY, footprint.centerZ)
	parts[#parts + 1] =
		box(WALL_THICKNESS, PARAPET_HEIGHT, footprint.depth - 2, halfW - 0.5, parapetY, footprint.centerZ)
	local slabs: { ShellPart } = {}
	addCutSlabs(slabs, -halfW, halfW, footprint.frontZ, footprint.backZ, footprint.roofTop, {
		minX = core.minX,
		maxX = core.maxX,
		minZ = core.minZ,
		maxZ = core.maxZ,
	})
	mergeFrom(parts, slabs)
	local coreCenterX = (core.minX + core.maxX) / 2
	local coreCenterZ = (core.minZ + core.maxZ) / 2
	local bulkheadWallHeight = StairCore.BULKHEAD_WALL_HEIGHT_STUDS
	parts[#parts + 1] = box(
		StairCore.CORE_WIDTH_STUDS + 2,
		bulkheadWallHeight,
		StairCore.CORE_DEPTH_STUDS + 2,
		coreCenterX,
		footprint.roofTop + bulkheadWallHeight / 2,
		coreCenterZ
	)
	parts[#parts + 1] = box(
		StairCore.CORE_WIDTH_STUDS + 2,
		1,
		StairCore.CORE_DEPTH_STUDS + 2,
		coreCenterX,
		footprint.roofTop + bulkheadWallHeight + 0.5,
		coreCenterZ
	)
	return table.freeze(parts)
end

--------------------------------------------------------------------------------
-- Public surface
--------------------------------------------------------------------------------

local layoutCache: { [number]: { SlotLayout } } = {}
local shellCache: { [number]: Shell } = {}
local ghostCache: { [number]: { ShellPart } } = {}

local HousePlan = {}

HousePlan.FLOORS_BY_TIER = FLOORS_BY_TIER
HousePlan.FLOOR_PITCH_STUDS = FLOOR_PITCH -- re-export of LobbyConfig.HOUSE (D3)
HousePlan.WALL_HEIGHT_STUDS = WALL_HEIGHT
HousePlan.SLAB_THICKNESS_STUDS = SLAB_THICKNESS
HousePlan.WALL_THICKNESS_STUDS = WALL_THICKNESS
HousePlan.SHELL_CLEARANCE_STUDS = SHELL_CLEARANCE
HousePlan.PARTS_PER_PODIUM = PARTS_PER_PODIUM
HousePlan.VACANT_DRESSING_PART_ALLOWANCE = VACANT_DRESSING_PART_ALLOWANCE
HousePlan.OWNER_SIGN_PART_ALLOWANCE = OWNER_SIGN_PART_ALLOWANCE

function HousePlan.SlotCount(tier: number): number
	assertTier(tier)
	return slotCountForTier(tier)
end

function HousePlan.SlotLayouts(tier: number): { SlotLayout }
	assertTier(tier)
	local cached = layoutCache[tier]
	if cached ~= nil then
		return cached
	end
	local layouts = buildLayouts(tier)
	assert(
		#layouts == slotCountForTier(tier),
		`HousePlan: tier {tier} layout drifted ({#layouts} slots vs {slotCountForTier(tier)} of record)`
	)
	local frozen = table.freeze(layouts)
	layoutCache[tier] = frozen
	return frozen
end

-- D3 footprint + D6 heights of record (replaces HOUSE_WIDTH/DEPTH/CENTER_Z).
function HousePlan.Footprint(tier: number): Footprint
	assertTier(tier)
	assert(tier >= 1, "HousePlan: vacant lots have no footprint of record")
	return footprintOf(tier)
end

-- §2.3 keep-clears of record (arrival pad / run-bottom / core rect).
function HousePlan.StairKeepClears(tier: number): { KeepClear }
	assertTier(tier)
	assert(tier >= 1, "HousePlan: vacant lots have no stair core")
	return stairCoreOf(tier).keepClears
end

function HousePlan.ShellPlan(tier: number): Shell
	assertTier(tier)
	local cached = shellCache[tier]
	if cached ~= nil then
		return cached
	end
	local shell = buildShell(tier)
	shellCache[tier] = shell
	return shell
end

-- Memoized ghost plan (D2): exterior walls + parapet + roof + bulkhead only.
function HousePlan.GhostPlan(tier: number): { ShellPart }
	assertTier(tier)
	local cached = ghostCache[tier]
	if cached ~= nil then
		return cached
	end
	local ghost = buildGhost(tier)
	ghostCache[tier] = ghost
	return ghost
end

-- Exact part count of the ShellPlan (one Part per entry, all five lists).
function HousePlan.EstimateShellParts(tier: number): number
	local shell = HousePlan.ShellPlan(tier)
	return #shell.walls + #shell.slabs + #shell.stairs + #shell.windows + #shell.neon
end

-- Whole-lot estimate (shell + podiums + dressing/sign allowance) — the value
-- PART_BUDGET_HOUSE_BY_TIER binds (D4).
function HousePlan.EstimateParts(tier: number): number
	assertTier(tier)
	local podiumParts = slotCountForTier(tier) * PARTS_PER_PODIUM
	local dressing = if tier == 0 then VACANT_DRESSING_PART_ALLOWANCE else OWNER_SIGN_PART_ALLOWANCE
	return HousePlan.EstimateShellParts(tier) + podiumParts + dressing
end

--------------------------------------------------------------------------------
-- Require-time invariants (WP2.1 items 2/4/6): a plan that breaches the lot,
-- the nesting contract, a stair keep-clear or a tier budget cap must fail at
-- require time, not at build time.
--------------------------------------------------------------------------------

-- T3 sits EXACTLY at the 2-stud envelope (D3); every tier nests >= 2/side.
assert(
	FOOTPRINTS[3].width + 2 * SHELL_CLEARANCE == LOT_FRONTAGE,
	"HousePlan: T3 must sit exactly at the 2-stud frontage envelope"
)
assert(
	FOOTPRINTS[3].backZ + SHELL_CLEARANCE == LOT_DEPTH / 2,
	"HousePlan: T3 must sit exactly at the 2-stud back envelope"
)
assert(FOOTPRINTS[3].frontZ - SHELL_CLEARANCE >= -LOT_DEPTH / 2, "HousePlan: T3 front breaches the lot line")
for tier = 1, 2 do
	local inner = FOOTPRINTS[tier]
	local outer = FOOTPRINTS[tier + 1]
	assert(
		(outer.width - inner.width) / 2 >= SHELL_CLEARANCE
			and inner.frontZ - outer.frontZ >= SHELL_CLEARANCE
			and outer.backZ - inner.backZ >= SHELL_CLEARANCE,
		`HousePlan: tier {tier}->{tier + 1} footprint nesting fell under 2 studs/side (ghost z-fight risk)`
	)
end

-- §3 podium tables clear every §2.3 stair keep-clear by a plinth radius.
for tier = 1, 3 do
	for _, slot in HousePlan.SlotLayouts(tier) do
		for _, clear in HousePlan.StairKeepClears(tier) do
			local nearestX = math.clamp(slot.x, clear.minX, clear.maxX)
			local nearestZ = math.clamp(slot.z, clear.minZ, clear.maxZ)
			local distance = math.sqrt((slot.x - nearestX) ^ 2 + (slot.z - nearestZ) ^ 2)
			assert(
				distance >= PLINTH_RADIUS - 1e-6,
				`HousePlan: tier {tier} {slot.slotId} inside the {clear.kind} keep-clear`
			)
		end
	end
	assert(PODIUM_SPACING <= 5.5, "HousePlan: §3 gallery tables assume the 5-stud spacing floor of record")
end

-- D4 tier caps bind at require time (Addendum 4 §6 line items per tier).
for tier = 1, 3 do
	local cap = LobbyConfig.PART_BUDGET_HOUSE_BY_TIER[tier]
	assert(
		HousePlan.EstimateParts(tier) <= cap,
		`HousePlan: tier {tier} estimate {HousePlan.EstimateParts(tier)} busts the {cap} cap`
	)
	-- Collidable parts stay off the street apron (AC-R5.5, D5; rotated AABB
	-- via the D1 closed form — orientation is X-only by contract).
	local shell = HousePlan.ShellPlan(tier)
	for _, list in { shell.walls, shell.slabs, shell.stairs } do
		for _, entry in list do
			local theta = math.rad(if entry.orientation ~= nil then entry.orientation.X else 0)
			local halfZ = (entry.size.Z * math.abs(math.cos(theta)) + entry.size.Y * math.abs(math.sin(theta))) / 2
			assert(
				entry.offset.Z - halfZ >= APRON_Z - 1e-6,
				`HousePlan: tier {tier} collidable part reaches the apron strip`
			)
		end
	end
end

return table.freeze(HousePlan)
