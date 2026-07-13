--!strict
-- Lobby budget suite (lobby SOP §4.1 capacities, §10 part/light budgets,
-- §6.2 queue rules, §11.1 sign distances; LOBBY_BUILD_PLAN WP2.7). Pure math
-- over the SHIPPED Shared.Config.LobbyConfig + Shared.Logic.HousePlan — the
-- exact tables the builders and the ghost preview render from — so every
-- SOP number and budget cap is pinned before a single Part exists.
--
-- WP4.5 reconciliation: the "as-built" section at the bottom re-derives the
-- Wave 2/3 builders' actual part/light/particle counts as pure arithmetic
-- (each constant cites the builder that owns it) and pins them inside the
-- HousePlan allowances and SOP caps. If a builder grows past its envelope,
-- the matching constant here MUST be re-derived from the new code — that
-- forced re-read is the tripwire.
--
-- R2 reconciliation pass 1 (LOBBY_SOP_ADDENDUM Changes 1/3/5/6/8; WP1.6):
-- feature census rebalanced (fountain PointLight slot -> swap-meet light),
-- plaza particle budget re-pinned to the hero sparkles, Change-1 cone math
-- and beacon-height caps pinned, and the new DISPATCH metronome constants
-- pinned against GameConstants.INTERMISSION_SECONDS. The light pin stays an
-- EQUALITY at exactly 50 before, during, and after every R2 wave.
--
-- R2 reconciliation final (WP6.3): the retired pad FSM's clamp/lock/re-arm
-- pins (5/1/2) dropped with their dead config keys (WP6.2); the surviving
-- QUEUE_SECONDS/QUEUE_CAPACITY keys now pin AGAINST DISPATCH so the metronome
-- has exactly one cycle length and one bin size of record. Spec sweep
-- (LockerBank/Fountain/"Wall of"/RosterBoard over src/server/Tests): zero
-- hits — the TestEZ specs pin the data layer only, no drift to update.
--
-- Addendum 2 (R3) pins (WP1.7): STEP_PLATE geometry + hysteresis of record
-- (the server builder and the client stand-on-plate predicate share these
-- exact numbers — R3-3), the BIKE speed pins (above sprint so mounting is
-- worth it; BOTH WalkSpeed owners read BIKE_SPEED_MULT off the server-set
-- BikeActive attribute — R3-5), the HERO.LABEL_* prune (R3-2: figures are
-- text-free, the wall carries the names), and the Neon-only key sweep
-- extended to the new STEP_PLATE/BIKE blocks. The 50-light EQUALITY pin
-- below is untouched: R3 adds ZERO Light instances (step-plate trim and
-- bike strip are Neon material only).
--
-- Addendum 3 (R4) re-pin (WP1.7): BIKE_SPEED_MULT is 2.2 (R4-3). The old
-- "inside the anti-speed validator cap" pin is INVERTED — 30.8 studs/s now
-- sits deliberately ABOVE the 27 cap; safety is structural, not numeric
-- (recorded rationale lives on the BIKE test below), with a 2.5x
-- exploit-read ceiling pin. Pins updated, never deleted; the 50-light
-- equality stays untouched (R4 adds ZERO Light instances).
-- StreetBuilder gains 5 parts per lot (plate + 4 border trim ≈ 100 across
-- the 20 lots; WP1.1 header cites the count), charged to the
-- PART_BUDGET_STREET_AND_LANDMARKS cap — this suite carries no as-built
-- street part census, so there is no street assertion to re-derive.
--
-- Addendum 4 (R5) Wave-1 cap re-pin (WP1.3): the flat per-shell 400 cap pin
-- is SUCCEEDED by the tiered WHOLE-LOT caps of record
-- (PART_BUDGET_HOUSE_BY_TIER = {160, 240, 450}, binding EstimateParts), the
-- street/landmark cap rises 3000 -> 4000 and the lobby total 15000 -> 20000
-- (justification on the worst-case test). Geometry pins in this file still
-- pin the OLD shell plan ON PURPOSE: the R5 migration of record is two-step
-- (caps re-pinned Wave 1 here, geometry re-pinned Wave 2 by WP2.4) and the
-- suite stays green throughout because the old shell already fits the new
-- tiered caps (≈ 53/99/234 vs 160/240/450). The new stair-core geometry is
-- pinned by the R5 house_stairs suite, not here (yet).
--
-- Addendum 4 (R5) Wave-2 geometry re-pin (WP2.4): step two of the migration
-- above — every OLD-plan geometry pin below is SUCCEEDED in place (pins
-- updated, never deleted; each rewritten test names its predecessor). The
-- shell of record is now the D2 five-list Shell (walls/slabs/stairs/windows/
-- neon; the WedgePart envelope ramp list is DELETED), circulation is the §2
-- U-switchback core of thin rotated planks (generator detail — slopes,
-- lengths, headroom, no-overlap — stays pinned by tests/suites/house_stairs;
-- THIS suite pins HousePlan's COMPOSITION of it per tier), podium floors run
-- the §3 gallery loop, and the new Footprint / GhostPlan / StairKeepClears
-- exports carry the §1/§5 massing + preview contract. New pins: D5 fit rule
-- + AC-R5.5 apron strip, footprint nesting, ghost no-coplanar, D8 night
-- palette (max channel >= 217), D2 orientation discipline, the D6 T3 blade
-- cap, and the D9/D5 tombstones (HOUSING_TIER_SLOTS 12/24/60,
-- STEP_PLATE.LOCAL_Z -29.5).

local GameConstants = require("../../src/shared/Config/GameConstants")
local LobbyConfig = require("../../src/shared/Config/LobbyConfig")
local HousePlan = require("../../src/shared/Logic/HousePlan")
local expect = require("../expect")

local tests = {}
local function test(name: string, fn: () -> ())
	table.insert(tests, { name = name, fn = fn })
end

--------------------------------------------------------------------------------
-- Shared helpers
--------------------------------------------------------------------------------

local TIERS = { 0, 1, 2, 3 }
local PLINTH_RADIUS = LobbyConfig.PODIUM.PLINTH_DIAMETER_STUDS / 2
local HALF_FRONTAGE = LobbyConfig.LOT_FRONTAGE_STUDS / 2
local HALF_DEPTH = LobbyConfig.LOT_DEPTH_STUDS / 2
local CLEARANCE = HousePlan.SHELL_CLEARANCE_STUDS

-- R5 storey constants of record (WP1.2 LobbyConfig.HOUSE block; plan D3).
local HOUSE = (LobbyConfig :: any).HOUSE
local PITCH = HOUSE.FLOOR_PITCH_STUDS :: number -- 10 (9 wall + 1 slab)
local FFL1 = HOUSE.FFL1_BY_TIER :: { number } -- { 1, 3, 3 }

-- Suite-local mirror of the D2 ShellPart contract so every pin compiles
-- against the binding shape (orientation/color optional), not against
-- whatever types the module under test happens to export.
type Dim3 = { X: number, Y: number, Z: number }
type Rgb = { R: number, G: number, B: number }
type Part = { size: Dim3, offset: Dim3, orientation: Dim3?, color: Rgb? }
type Rect = { minX: number, maxX: number, minZ: number, maxZ: number, kind: string? }

-- D2 Shell category lists of record: walls/slabs/stairs collide,
-- windows/neon are no-collide decor.
local SHELL_LISTS = { "walls", "slabs", "stairs", "windows", "neon" }
local COLLIDE_LISTS = { "walls", "slabs", "stairs" }

-- §1.1-1.3 stair-core rectangles of record (lot-local, back-right corner,
-- 13 x 14 at every tier; the mouth plane is each rect's -Z edge).
local CORE_RECTS: { [number]: Rect } = {
	[1] = { minX = 2.5, maxX = 15.5, minZ = 0.5, maxZ = 14.5 },
	[2] = { minX = 4.5, maxX = 17.5, minZ = 6, maxZ = 20 },
	[3] = { minX = 6.5, maxX = 19.5, minZ = 10.5, maxZ = 24.5 },
}

-- §3 gallery-loop zone planes per tier (lot-local): wall rows sit 3 studs
-- off the interior wall faces (|x| = rowX), the back focal pair shares one
-- z plane; everything else on a floor is a staggered center island.
local GALLERY_PLANES = {
	[1] = { rowX = 12.5, backZ = 11.5 },
	[2] = { rowX = 14.5, backZ = 17 },
	[3] = { rowX = 16.5, backZ = 21.5 },
}
-- §3 zone census per tier ({left, back, right, islands}; totals 12).
local GALLERY_CENSUS = {
	[1] = { left = 5, back = 2, right = 2, islands = 3 },
	[2] = { left = 5, back = 2, right = 2, islands = 3 },
	[3] = { left = 4, back = 2, right = 3, islands = 3 },
}
-- §3 T3 floor-5 setback signature (the right row and islands shift with the
-- penthouse front wall; left row and back pair stay), vs floors 1-4.
local T3_F5_RIGHT_Z = { -11, -4.5, 2 }
local T3_F5_ISLANDS = { { -4, 0 }, { 0, -8 }, { 0, 8 } }
local T3_F14_RIGHT_Z = { -14, -7, 0 }
local T3_F14_ISLANDS = { { -4, -1 }, { 0, -10 }, { 0, 8 } }

-- Slots grouped into floors by their y level, ascending.
local function floorsOf(tier: number): { { HousePlan.SlotLayout } }
	local byY: { [number]: { HousePlan.SlotLayout } } = {}
	local levels: { number } = {}
	for _, slot in HousePlan.SlotLayouts(tier) do
		if byY[slot.y] == nil then
			byY[slot.y] = {}
			table.insert(levels, slot.y)
		end
		table.insert(byY[slot.y] :: { HousePlan.SlotLayout }, slot)
	end
	table.sort(levels)
	local floors: { { HousePlan.SlotLayout } } = {}
	for _, y in levels do
		table.insert(floors, byY[y] :: { HousePlan.SlotLayout })
	end
	return floors
end

-- One named D2 category list, asserted into existence: a Shell that lost a
-- list of record fails loudly here, not as a silent empty iteration.
local function listOf(tier: number, listName: string): { Part }
	local shell = HousePlan.ShellPlan(tier) :: any
	local list = shell[listName]
	expect.ok(type(list) == "table", `tier {tier} Shell.{listName} list of record exists (plan D2)`)
	return list :: { Part }
end

local function partsOf(tier: number, listNames: { string }): { Part }
	local parts: { Part } = {}
	for _, listName in listNames do
		for _, part in listOf(tier, listName) do
			table.insert(parts, part)
		end
	end
	return parts
end

-- Closed-form rotated AABB (plan D1): orientation is constrained to the X
-- (width) axis, so aabbY = sizeY·cos + sizeZ·sin, aabbZ = sizeZ·cos +
-- sizeY·sin, and X is unchanged. Axis-aligned parts pass through untouched.
local function rotatedAabb(part: Part): (number, number, number, number, number, number)
	local degX = if part.orientation ~= nil then part.orientation.X else 0
	local theta = math.rad(degX)
	local halfX = part.size.X / 2
	local halfY = (part.size.Y * math.abs(math.cos(theta)) + part.size.Z * math.abs(math.sin(theta))) / 2
	local halfZ = (part.size.Z * math.abs(math.cos(theta)) + part.size.Y * math.abs(math.sin(theta))) / 2
	return part.offset.X - halfX,
		part.offset.X + halfX,
		part.offset.Y - halfY,
		part.offset.Y + halfY,
		part.offset.Z - halfZ,
		part.offset.Z + halfZ
end

-- Distance from a podium center (XZ circle center) to the nearest point of
-- an XZ rectangle; 0 means the center is inside the rectangle.
local function rectClearance(cx: number, cz: number, minX: number, maxX: number, minZ: number, maxZ: number): number
	local nearestX = math.clamp(cx, minX, maxX)
	local nearestZ = math.clamp(cz, minZ, maxZ)
	return math.sqrt((cx - nearestX) ^ 2 + (cz - nearestZ) ^ 2)
end

type Zones = {
	left: { HousePlan.SlotLayout },
	back: { HousePlan.SlotLayout },
	right: { HousePlan.SlotLayout },
	islands: { HousePlan.SlotLayout },
}

-- Classify one floor's podiums into the §3 gallery-loop zones by the binding
-- row planes (exact-coordinate matching, tolerance 0.01).
local function zonesOf(tier: number, floor: { HousePlan.SlotLayout }): Zones
	local planes = GALLERY_PLANES[tier]
	local zones: Zones = { left = {}, back = {}, right = {}, islands = {} }
	for _, slot in floor do
		if math.abs(slot.x + planes.rowX) <= 0.01 then
			table.insert(zones.left, slot)
		elseif math.abs(slot.x - planes.rowX) <= 0.01 then
			table.insert(zones.right, slot)
		elseif math.abs(slot.z - planes.backZ) <= 0.01 then
			table.insert(zones.back, slot)
		else
			table.insert(zones.islands, slot)
		end
	end
	return zones
end

local function containsNear(values: { number }, want: number): boolean
	for _, value in values do
		if math.abs(value - want) <= 1e-3 then
			return true
		end
	end
	return false
end

local function sortedZs(slots: { HousePlan.SlotLayout }): { number }
	local zs: { number } = {}
	for _, slot in slots do
		table.insert(zs, slot.z)
	end
	table.sort(zs)
	return zs
end

local function sortedXZ(slots: { HousePlan.SlotLayout }): { { number } }
	local pairsList: { { number } } = {}
	for _, slot in slots do
		table.insert(pairsList, { slot.x, slot.z })
	end
	table.sort(pairsList, function(a, b)
		if a[1] ~= b[1] then
			return a[1] < b[1]
		end
		return a[2] < b[2]
	end)
	return pairsList
end

--------------------------------------------------------------------------------
-- SOP §4.1 — capacities & slot identity
--------------------------------------------------------------------------------

test("slot counts of record: 8 / 12 / 24 / 60 straight from GameConstants", function()
	expect.eq(#HousePlan.SlotLayouts(0), GameConstants.SHELF_BASE_SLOTS, "tier 0 vacant lot")
	expect.eq(#HousePlan.SlotLayouts(0), 8, "tier 0 is the verbatim 8 podiums")
	for tier = 1, 3 do
		expect.eq(
			#HousePlan.SlotLayouts(tier),
			GameConstants.HOUSING_TIER_SLOTS[tier],
			`tier {tier} matches HOUSING_TIER_SLOTS`
		)
	end
	expect.eq(#HousePlan.SlotLayouts(1), 12, "house displays 12")
	expect.eq(#HousePlan.SlotLayouts(2), 24, "two-story displays 24")
	expect.eq(#HousePlan.SlotLayouts(3), 60, "mansion displays 60")
	expect.eq(GameConstants.HOUSING_MAX_SLOTS, 60, "max slots agrees with the mansion")
end)

test("slot ids are s1..sN in order — the exact shape ShelfService validates", function()
	for _, tier in TIERS do
		for position, slot in HousePlan.SlotLayouts(tier) do
			expect.eq(slot.slotId, `s{position}`, `tier {tier} slot {position} id`)
			expect.ok(string.match(slot.slotId, "^s(%d+)$") ~= nil, `tier {tier} id parses as ^s%d+$`)
			expect.ok(#slot.slotLabel > 0, `tier {tier} slot {position} has a label`)
		end
	end
end)

--------------------------------------------------------------------------------
-- SOP §1.1 / §1.2 — street & lot dimensions of record
--------------------------------------------------------------------------------

test("lot 45 x 55 with 8-stud gaps; corridor 38 + 2 x 9 >= 56", function()
	expect.eq(LobbyConfig.LOT_FRONTAGE_STUDS, 45, "lot frontage")
	expect.eq(LobbyConfig.LOT_DEPTH_STUDS, 55, "lot depth")
	expect.eq(LobbyConfig.LOT_GAP_STUDS, 8, "gap between lots")
	expect.eq(LobbyConfig.LOTS_PER_SIDE, 10, "10 lots per side")
	expect.eq(LobbyConfig.LOTS_PER_SIDE * 2, GameConstants.HUB_DISPLAY_STATION_COUNT, "20 lots of record")
	expect.eq(
		LobbyConfig.CORRIDOR_WIDTH_STUDS,
		LobbyConfig.STREET_ASPHALT_WIDTH_STUDS + 2 * LobbyConfig.SIDEWALK_WIDTH_STUDS,
		"corridor = asphalt + both sidewalks"
	)
	expect.ok(LobbyConfig.CORRIDOR_WIDTH_STUDS >= 56, "corridor of record >= 56")
end)

--------------------------------------------------------------------------------
-- SOP §4.1 — plan geometry
--------------------------------------------------------------------------------

test("tier 0: 2 x 4 grid on the grass facing the street at 5-stud spacing", function()
	local rows: { [number]: number } = {}
	local columns: { [number]: boolean } = {}
	for _, slot in HousePlan.SlotLayouts(0) do
		expect.eq(slot.y, 0, "vacant podiums stand on the grass")
		rows[slot.z] = (rows[slot.z] or 0) + 1
		columns[slot.x] = true
	end
	local rowZs: { number } = {}
	for z, count in rows do
		expect.eq(count, 4, `row z={z} holds 4 podiums`)
		table.insert(rowZs, z)
	end
	table.sort(rowZs)
	expect.eq(#rowZs, 2, "exactly 2 rows")
	expect.eq(rowZs[2] - rowZs[1], LobbyConfig.PODIUM.SPACING_STUDS, "rows 5 studs apart")
	expect.ok(rowZs[2] < 0, "both rows sit on the street half of the lot (-Z faces the street)")

	local columnXs: { number } = {}
	for x in columns do
		table.insert(columnXs, x)
	end
	table.sort(columnXs)
	expect.eq(#columnXs, 4, "exactly 4 columns")
	for index = 2, 4 do
		expect.eq(columnXs[index] - columnXs[index - 1], LobbyConfig.PODIUM.SPACING_STUDS, "columns 5 studs apart")
	end
	expect.eq(columnXs[1], -columnXs[4], "grid centered on the lot")
end)

test("tiers 1/2/3 stack 1/2/5 twelve-podium floors at ffl1 + (i - 1) x 10 (FFL1 1/3/3)", function()
	-- Pin succession (R5 WP2.4; predecessor pinned floor tops at
	-- SLAB_THICKNESS + (i - 1) x 9). D3's formula of record is
	-- Footprint(tier).ffl1 + (floorIndex - 1) x FLOOR_PITCH_STUDS: pitch
	-- raised to 10 (9 wall + 1 slab), FFL1 1/3/3 (T1 slab-on-pad, T2/T3
	-- raised stoop), ground slab = ONE plate of thickness == FFL1.
	expect.eq(HousePlan.FLOOR_PITCH_STUDS, 10, "pitch of record re-exported by HousePlan (plan D3)")
	expect.eq(HousePlan.FLOOR_PITCH_STUDS, PITCH, "HousePlan pitch == LobbyConfig.HOUSE pitch (one source)")
	expect.eq(FFL1[1], 1, "tier 1 FFL1 of record")
	expect.eq(FFL1[2], 3, "tier 2 FFL1 of record")
	expect.eq(FFL1[3], 3, "tier 3 FFL1 of record")
	for tier = 1, 3 do
		local footprint = (HousePlan :: any).Footprint(tier)
		expect.eq(footprint.ffl1, FFL1[tier], `tier {tier} Footprint.ffl1 == FFL1_BY_TIER[{tier}]`)
		local floors = floorsOf(tier)
		expect.eq(#floors, HousePlan.FLOORS_BY_TIER[tier], `tier {tier} floor count`)
		for floorIndex, floor in floors do
			expect.eq(#floor, 12, `tier {tier} floor {floorIndex} holds 12 podiums`)
			local wantY = FFL1[tier] + (floorIndex - 1) * PITCH
			expect.eq(floor[1].y, wantY, `tier {tier} floor {floorIndex} sits on its slab top`)
		end
	end
end)

test("podium spacing >= 5 on every floor of every tier", function()
	for _, tier in TIERS do
		for floorIndex, floor in floorsOf(tier) do
			for a = 1, #floor do
				for b = a + 1, #floor do
					local distance = math.sqrt((floor[a].x - floor[b].x) ^ 2 + (floor[a].z - floor[b].z) ^ 2)
					expect.ok(
						distance >= LobbyConfig.PODIUM.SPACING_STUDS,
						`tier {tier} floor {floorIndex}: {floor[a].slotId}<->{floor[b].slotId} spaced {distance}`
					)
				end
			end
		end
	end
end)

test("gallery loop spot checks: island<->row >= 6.5, island<->island >= 5.5, door fan >= 5.5", function()
	-- Pin succession (R5 WP2.4, plan D7; predecessor pinned the dead 8-10
	-- stud central aisle of the two-side-row template). The §3 gallery loop
	-- staggers three center islands instead, so the walkability contract is
	-- now center-distance spot checks against the binding §3 coordinates:
	-- every island >= 6.5 from every wall-row/back podium, islands >= 5.5
	-- apart, and every floor-1 podium >= 5.5 from the door fan point (x 0 on
	-- the interior face of the 1-thick front wall — keep-clear (c) of §3).
	for tier = 1, 3 do
		local doorZ = (HousePlan :: any).Footprint(tier).frontZ + 1
		for floorIndex, floor in floorsOf(tier) do
			local zones = zonesOf(tier, floor)
			local perimeter: { HousePlan.SlotLayout } = {}
			for _, zone in { zones.left, zones.back, zones.right } do
				for _, slot in zone do
					table.insert(perimeter, slot)
				end
			end
			for _, island in zones.islands do
				for _, slot in perimeter do
					local distance = math.sqrt((island.x - slot.x) ^ 2 + (island.z - slot.z) ^ 2)
					expect.ok(
						distance >= 6.5 - 1e-6,
						`tier {tier} floor {floorIndex}: island {island.slotId} {distance} from row {slot.slotId} (need 6.5)`
					)
				end
			end
			for a = 1, #zones.islands do
				for b = a + 1, #zones.islands do
					local islandA, islandB = zones.islands[a], zones.islands[b]
					local distance = math.sqrt((islandA.x - islandB.x) ^ 2 + (islandA.z - islandB.z) ^ 2)
					expect.ok(
						distance >= 5.5 - 1e-6,
						`tier {tier} floor {floorIndex}: islands {islandA.slotId}<->{islandB.slotId} {distance} (need 5.5)`
					)
				end
			end
			if floorIndex == 1 then
				for _, slot in floor do
					local distance = math.sqrt(slot.x ^ 2 + (slot.z - doorZ) ^ 2)
					expect.ok(
						distance >= 5.5 - 1e-6,
						`tier {tier} {slot.slotId} {distance} from the door fan point (need 5.5)`
					)
				end
			end
		end
	end
end)

test("§3 gallery zone census every tier/floor + the T3 floor-5 setback signature", function()
	-- Pin succession (R5 WP2.4, plan D7; predecessors pinned the mansion
	-- ground-floor 5+2+5 U-perimeter and the SIDE_COLUMN_Z side template —
	-- both die with R5). Every floor of every tier now runs the §3 gallery
	-- loop: left wall row + back focal pair + right wall row + 3 staggered
	-- center islands (12 total), rows 3 studs off the interior wall faces.
	-- T3 floor 5 is the penthouse setback variant: right row z -11/-4.5/+2
	-- and islands (-4,0)/(0,-8)/(0,+8); left row and back pair unchanged.
	for tier = 1, 3 do
		local census = GALLERY_CENSUS[tier]
		for floorIndex, floor in floorsOf(tier) do
			local zones = zonesOf(tier, floor)
			expect.eq(#zones.left, census.left, `tier {tier} floor {floorIndex} left wall row of {census.left}`)
			expect.eq(#zones.back, census.back, `tier {tier} floor {floorIndex} back focal pair`)
			expect.eq(#zones.right, census.right, `tier {tier} floor {floorIndex} right wall row of {census.right}`)
			expect.eq(#zones.islands, census.islands, `tier {tier} floor {floorIndex} three center islands`)
		end
	end

	local mansionFloors = floorsOf(3)
	for floorIndex = 1, 4 do
		local zones = zonesOf(3, mansionFloors[floorIndex])
		expect.deepEq(sortedZs(zones.right), T3_F14_RIGHT_Z, `mansion floor {floorIndex} right row at z -14/-7/0`)
		expect.deepEq(sortedXZ(zones.islands), T3_F14_ISLANDS, `mansion floor {floorIndex} islands of record`)
	end
	local penthouse = zonesOf(3, mansionFloors[5])
	expect.deepEq(sortedZs(penthouse.right), T3_F5_RIGHT_Z, "floor-5 right row shifted to z -11/-4.5/+2 (setback)")
	expect.deepEq(sortedXZ(penthouse.islands), T3_F5_ISLANDS, "floor-5 islands shifted with the setback front wall")
	expect.deepEq(
		sortedZs(zonesOf(3, mansionFloors[5]).left),
		sortedZs(zonesOf(3, mansionFloors[1]).left),
		"floor-5 left row unchanged"
	)
end)

--------------------------------------------------------------------------------
-- D2 contract, footprints & fit (R5 WP2.4)
--------------------------------------------------------------------------------

test("D2 Shell contract: exactly floors + the five category lists; estimate sums all five", function()
	-- Pin succession (R5 WP2.4, plan D2; predecessor shape carried the
	-- WedgePart envelope list between slabs and windows — that key is
	-- DELETED, so ANY key outside the D2 set fails here, stale or new).
	local allowed: { [string]: boolean } =
		{ floors = true, walls = true, slabs = true, stairs = true, windows = true, neon = true }
	for tier = 1, 3 do
		local shell = HousePlan.ShellPlan(tier) :: any
		for key in shell :: { [string]: any } do
			expect.ok(allowed[key] == true, `tier {tier} Shell.{key} is a D2 key of record`)
		end
		expect.eq(shell.floors, HousePlan.FLOORS_BY_TIER[tier], `tier {tier} floor count of record`)
		local total = 0
		for _, listName in SHELL_LISTS do
			total += #listOf(tier, listName)
		end
		expect.ok(#listOf(tier, "stairs") > 0, `tier {tier} ships a stair core`)
		expect.ok(#listOf(tier, "neon") > 0, `tier {tier} ships Neon dressing`)
		expect.eq(HousePlan.EstimateShellParts(tier), total, `tier {tier} EstimateShellParts sums all five lists`)
	end
end)

test("Footprint(tier) of record: 33x30 / 37x38 / 41x45 with heights 11..20 / 23..32 / 53..62", function()
	-- New pin (R5 WP2.4, plan D2/D3/D6; predecessors were the deleted
	-- single-mass HOUSE_WIDTH/DEPTH/CENTER_Z exports, 18 x 42 at z +2.5).
	local want = {
		[1] = { width = 33, depth = 30, frontZ = -14.5, backZ = 15.5 },
		[2] = { width = 37, depth = 38, frontZ = -17, backZ = 21 },
		[3] = { width = 41, depth = 45, frontZ = -19.5, backZ = 25.5 },
	}
	for tier = 1, 3 do
		local footprint = (HousePlan :: any).Footprint(tier)
		local wanted = want[tier]
		expect.eq(footprint.width, wanted.width, `tier {tier} footprint width of record`)
		expect.eq(footprint.depth, wanted.depth, `tier {tier} footprint depth of record`)
		expect.eq(footprint.frontZ, wanted.frontZ, `tier {tier} front plane of record`)
		expect.eq(footprint.backZ, wanted.backZ, `tier {tier} back plane of record`)
		expect.near(footprint.centerZ, (wanted.frontZ + wanted.backZ) / 2, 1e-9, `tier {tier} centerZ centered`)
		expect.eq(footprint.ffl1, FFL1[tier], `tier {tier} ffl1 of record`)
		local floors = HousePlan.FLOORS_BY_TIER[tier]
		expect.eq(footprint.roofTop, FFL1[tier] + floors * PITCH, `tier {tier} roof slab top (D6: 11/23/53)`)
		expect.eq(footprint.parapetTop, footprint.roofTop + 4, `tier {tier} parapet 4 high (§4 binding minimum 3)`)
		expect.eq(footprint.bulkheadTop, footprint.roofTop + 9, `tier {tier} bulkhead cap top (D6: 20/32/62)`)
	end
end)

test("footprint nesting >= 2 studs per side per tier step (the §5 no-z-fight precondition)", function()
	-- New pin (R5 WP2.4, plan D2/§1.0): 33/30 -> 37/38 -> 41/45 strictly
	-- nested so no ghost wall plane can ever be coplanar with a built one.
	for tier = 1, 2 do
		local inner = (HousePlan :: any).Footprint(tier)
		local outer = (HousePlan :: any).Footprint(tier + 1)
		expect.ok((outer.width - inner.width) / 2 >= 2, `tier {tier}->{tier + 1} width steps >= 2 per side`)
		expect.ok(inner.frontZ - outer.frontZ >= 2, `tier {tier}->{tier + 1} front plane steps >= 2 forward`)
		expect.ok(outer.backZ - inner.backZ >= 2, `tier {tier}->{tier + 1} back plane steps >= 2 back`)
	end
end)

test("D5 fit: tall parts inside the 2-stud envelope; ALL parts |x| <= 22, |z| <= 27; apron strip clear", function()
	-- Pin succession (R5 WP2.4, plan D5; predecessor held EVERY shell part
	-- to the 2-stud lot clearance). R5 yard dressing (fences <= 1.2, hedges
	-- <= 2, path <= 0.15 proud) legally sits outside the house envelope, so
	-- the 2-stud-clearance envelope now binds only parts with rotated-AABB
	-- height > 2.5 (anything a character cannot auto-step over); ALL parts
	-- still stay inside |x| 22 / |z| 27, and the street apron strip
	-- z [-27.5, -23.5] holds ZERO collidable house parts at any tier
	-- (AC-R5.5 — the step-plate approach and the owner sign own that strip).
	for _, tier in TIERS do
		for _, slot in HousePlan.SlotLayouts(tier) do
			expect.ok(
				math.abs(slot.x) + PLINTH_RADIUS <= HALF_FRONTAGE - CLEARANCE,
				`tier {tier} {slot.slotId} inside the frontage`
			)
			expect.ok(
				math.abs(slot.z) + PLINTH_RADIUS <= HALF_DEPTH - CLEARANCE,
				`tier {tier} {slot.slotId} inside the depth`
			)
		end
		for index, part in partsOf(tier, SHELL_LISTS) do
			local minX, maxX, minY, maxY, minZ, maxZ = rotatedAabb(part)
			local reachX = math.max(math.abs(minX), math.abs(maxX))
			local reachZ = math.max(math.abs(minZ), math.abs(maxZ))
			expect.ok(reachX <= 22 + 1e-6, `tier {tier} part {index} inside the |x| 22 yard band (D5)`)
			expect.ok(reachZ <= 27 + 1e-6, `tier {tier} part {index} inside the |z| 27 yard band (D5)`)
			if maxY - minY > 2.5 then
				expect.ok(
					reachX <= HALF_FRONTAGE - CLEARANCE + 1e-6,
					`tier {tier} tall part {index} inside the frontage envelope (T3 sits exactly at it)`
				)
				expect.ok(
					reachZ <= HALF_DEPTH - CLEARANCE + 1e-6,
					`tier {tier} tall part {index} inside the depth envelope`
				)
			end
		end
		for index, part in partsOf(tier, COLLIDE_LISTS) do
			local _, _, _, _, minZ = rotatedAabb(part)
			expect.ok(
				minZ >= -23.5 - 1e-6,
				`tier {tier} collidable part {index} stays off the apron strip (z >= -23.5, AC-R5.5)`
			)
		end
	end
end)

--------------------------------------------------------------------------------
-- Stair composition & keep-clears (R5 WP2.4; generator detail lives in the
-- house_stairs suite — these pins hold HousePlan's per-tier COMPOSITION)
--------------------------------------------------------------------------------

test("podiums never intersect walls or stair parts on their own floor (rotated AABB)", function()
	-- Pin succession (R5 WP2.4; predecessor iterated walls + the WedgePart
	-- envelope list). The solids of record are now walls + stairs entries,
	-- planks swept via the D1 closed-form rotated AABB.
	for tier = 1, 3 do
		local solids = partsOf(tier, { "walls", "stairs" })
		for _, slot in HousePlan.SlotLayouts(tier) do
			local podiumTop = slot.y + 3 -- plinth + ring + display stand-in
			for index, part in solids do
				local minX, maxX, minY, maxY, minZ, maxZ = rotatedAabb(part)
				if minY < podiumTop and maxY > slot.y then
					expect.ok(
						rectClearance(slot.x, slot.z, minX, maxX, minZ, maxZ) >= PLINTH_RADIUS,
						`tier {tier} {slot.slotId} clears solid part {index}`
					)
				end
			end
		end
	end
end)

test("stair composition: floors x 2 thin planks + floors half-landings in the §1 core; y-chain flush", function()
	-- Pin succession (R5 WP2.4, plan D1/D2; predecessor pinned ONE
	-- full-pitch WedgePart envelope per transition, size.Y == pitch, at one
	-- XZ — the exact geometry Addendum 4 §2 abolishes). The stairs list now
	-- carries thin inclined planks (<= 1.2 thick; an envelope CANNOT pass) +
	-- half-landings inside the core rect, plus the tier's entry stoop planks
	-- out front. The y-chain proves each transition spans its storey: plank
	-- centers at +2.5/+7.5 over each floor top, landing top at +5, so flight
	-- B tops out flush with the next slab (zero vertical discontinuity).
	for tier = 1, 3 do
		local core = CORE_RECTS[tier]
		local floors = HousePlan.FLOORS_BY_TIER[tier]
		local plankYs: { number } = {}
		local landingTops: { number } = {}
		local entryParts = 0
		for index, part in listOf(tier, "stairs") do
			expect.ok(
				part.size.Y <= 1.2,
				`tier {tier} stairs[{index}] thickness {part.size.Y} <= 1.2 (full-pitch envelopes are extinct)`
			)
			local inCore = part.offset.X > core.minX - 1e-6
				and part.offset.X < core.maxX + 1e-6
				and part.offset.Z > core.minZ - 1e-6
				and part.offset.Z < core.maxZ + 1e-6
			if not inCore then
				entryParts += 1
			elseif part.orientation ~= nil then
				table.insert(plankYs, part.offset.Y)
			else
				table.insert(landingTops, part.offset.Y + part.size.Y / 2)
			end
		end
		expect.eq(#plankYs, floors * 2, `tier {tier} exactly floors x 2 inclined planks in the core`)
		expect.eq(#landingTops, floors, `tier {tier} exactly one half-landing per transition`)
		expect.ok(entryParts >= 1, `tier {tier} ships an entry stoop/incline outside the core`)
		for transition = 1, floors do
			local base = FFL1[tier] + (transition - 1) * PITCH
			expect.ok(
				containsNear(plankYs, base + 2.5),
				`tier {tier} transition {transition} flight A at mid-rise +2.5`
			)
			expect.ok(
				containsNear(plankYs, base + 7.5),
				`tier {tier} transition {transition} flight B at mid-rise +7.5`
			)
			expect.ok(containsNear(landingTops, base + 5), `tier {tier} transition {transition} half-landing top at +5`)
		end
	end
end)

test("StairKeepClears of record: arrival pad / run-bottom / core rects; every podium clears all three", function()
	-- New pin (R5 WP2.4, plan D2/D7): the §2.3 keep-clears are exports of
	-- record and the §3 podium tables must respect them on EVERY floor (the
	-- core is identical per storey). Cross-pins the §1.1-1.3 core rects.
	for tier = 1, 3 do
		local keepClears = (HousePlan :: any).StairKeepClears(tier) :: { Rect }
		expect.eq(#keepClears, 3, `tier {tier} exactly the three §2.3 keep-clears`)
		local byKind: { [string]: Rect } = {}
		for _, rect in keepClears do
			byKind[rect.kind :: string] = rect
		end
		local core = byKind.core
		expect.ok(core ~= nil, `tier {tier} core keep-clear of record exists`)
		local want = CORE_RECTS[tier]
		expect.near(core.minX, want.minX, 1e-3, `tier {tier} core rect west edge (§1 position)`)
		expect.near(core.maxX, want.maxX, 1e-3, `tier {tier} core rect east edge`)
		expect.near(core.minZ, want.minZ, 1e-3, `tier {tier} core rect mouth plane`)
		expect.near(core.maxZ, want.maxZ, 1e-3, `tier {tier} core rect back edge`)
		local pad = byKind.arrival_pad
		expect.ok(pad ~= nil, `tier {tier} arrival-pad keep-clear of record exists`)
		expect.near(pad.maxX - pad.minX, 6, 1e-3, `tier {tier} arrival pad 6 wide (west bay)`)
		expect.near(pad.maxZ - pad.minZ, 6, 1e-3, `tier {tier} arrival pad 6 deep`)
		expect.near(pad.maxZ, want.minZ, 1e-3, `tier {tier} arrival pad abuts the mouth plane`)
		expect.near(pad.minX, want.minX, 1e-3, `tier {tier} arrival pad fronts the WEST bay`)
		local runBottom = byKind.run_bottom
		expect.ok(runBottom ~= nil, `tier {tier} run-bottom keep-clear of record exists`)
		expect.near(runBottom.maxX - runBottom.minX, 13, 1e-3, `tier {tier} run-bottom spans the full mouth width`)
		expect.near(runBottom.maxZ - runBottom.minZ, 6, 1e-3, `tier {tier} run-bottom 6 deep`)
		expect.near(runBottom.maxZ, want.minZ, 1e-3, `tier {tier} run-bottom abuts the mouth plane`)
		for _, slot in HousePlan.SlotLayouts(tier) do
			for _, rect in keepClears do
				expect.ok(
					rectClearance(slot.x, slot.z, rect.minX, rect.maxX, rect.minZ, rect.maxZ) >= PLINTH_RADIUS - 1e-6,
					`tier {tier} {slot.slotId} clears the {rect.kind} keep-clear`
				)
			end
		end
	end
end)

--------------------------------------------------------------------------------
-- Orientation, palette, blade & ghost discipline (R5 WP2.4 new pins)
--------------------------------------------------------------------------------

test("orientation discipline: ONLY stairs entries rotate, ONLY about X, never past 35 degrees", function()
	-- New pin (R5 WP2.4, plan D2): orientation is the stairs lists' private
	-- privilege, X (width) axis only, derived from atan(rise/run) — so the
	-- closed-form rotated AABB above stays valid for every part forever.
	for tier = 1, 3 do
		for _, listName in { "walls", "slabs", "windows", "neon" } do
			for index, part in listOf(tier, listName) do
				expect.ok(
					part.orientation == nil,
					`tier {tier} {listName}[{index}] is axis-aligned (D2: only stairs rotate)`
				)
			end
		end
		for index, part in listOf(tier, "stairs") do
			local orientation = part.orientation
			if orientation ~= nil then
				expect.eq(orientation.Y, 0, `tier {tier} stairs[{index}] never yaws (D2: X only)`)
				expect.eq(orientation.Z, 0, `tier {tier} stairs[{index}] never rolls (D2: X only)`)
				expect.ok(math.abs(orientation.X) > 0, `tier {tier} stairs[{index}] rotation is real, not a 0 stub`)
				expect.ok(math.abs(orientation.X) <= 35, `tier {tier} stairs[{index}] inside the 35-degree comfort cap`)
			end
		end
		for index, part in (HousePlan :: any).GhostPlan(tier) :: { Part } do
			expect.ok(part.orientation == nil, `tier {tier} ghost part {index} axis-aligned (no stairs in the ghost)`)
		end
	end
end)

test("D8 night palette: windows/neon part colors and their palette sources at max(R,G,B) >= 217", function()
	-- New pin (R5 WP2.4, plan D8): HSV Value >= 0.85 == max channel >= 217
	-- (255 x 0.85), so every glow panel clears BLOOM.THRESHOLD (1.1) at
	-- night. Colors ship as frozen raw {R,G,B} tables ONLY — Color3.fromRGB
	-- happens at APPLY time in the builder/ghost (raw table -> Color3
	-- property assignment is the recurring boot-crash class).
	local palette = (LobbyConfig :: any).HOUSE_PALETTE
	local sources: { [string]: any } = { GOLD = palette.GOLD }
	for index, color in palette.TIER_IDENTITY :: { any } do
		sources[`TIER_IDENTITY[{index}]`] = color
	end
	for index, color in palette.T3_FLOOR_ACCENTS :: { any } do
		sources[`T3_FLOOR_ACCENTS[{index}]`] = color
	end
	for index, color in palette.T3_WINDOW_GRADIENT :: { any } do
		sources[`T3_WINDOW_GRADIENT[{index}]`] = color
	end
	for label, color in sources do
		expect.ok(table.isfrozen(color), `HOUSE_PALETTE.{label} ships frozen (D8)`)
		expect.ok(math.max(color.R, color.G, color.B) >= 217, `HOUSE_PALETTE.{label} at identity V (>= 217)`)
	end
	for tier = 1, 3 do
		for _, listName in { "windows", "neon" } do
			for index, part in listOf(tier, listName) do
				local color = part.color
				if color ~= nil then
					for _, channel in { color.R, color.G, color.B } do
						expect.ok(
							type(channel) == "number" and channel >= 0 and channel <= 255,
							`tier {tier} {listName}[{index}] channels inside fromRGB 0..255`
						)
					end
					expect.ok(
						math.max(color.R, color.G, color.B) >= 217,
						`tier {tier} {listName}[{index}] glow color at identity V (D8: max >= 217)`
					)
				end
			end
		end
	end
end)

test("D6 skyline: ONE T3 Neon blade 0.5 x 50 x 0.5 topping out under the 60-stud queue beacon", function()
	-- New pin (R5 WP2.4, plan D6/§1.3): the stair tower's full-height
	-- magenta blade is the tallest light on the STREET but never challenges
	-- the queue beacon (the one 60-stud landmark of record, pinned above);
	-- the matte bulkhead cap at 62 is architecture, not a light. Any Neon
	-- standing on the bulkhead cap is the §2.5 spire: 2 studs max.
	local footprint = (HousePlan :: any).Footprint(3)
	local blades: { Part } = {}
	for _, part in listOf(3, "neon") do
		if part.size.Y >= 40 then
			table.insert(blades, part)
		end
		local bottom = part.offset.Y - part.size.Y / 2
		if bottom >= footprint.bulkheadTop - 1e-6 then
			expect.ok(part.size.Y <= 2, `bulkhead-cap spire height {part.size.Y} <= 2 (D6)`)
		end
	end
	expect.eq(#blades, 1, "exactly one full-height blade on the mansion")
	local blade = blades[1]
	expect.near(blade.size.X, 0.5, 1e-6, "blade 0.5 wide (§1.3)")
	expect.near(blade.size.Z, 0.5, 1e-6, "blade 0.5 deep (§1.3)")
	expect.eq(blade.size.Y, 50, "blade 50 tall (§1.3)")
	expect.ok(
		blade.offset.Y + blade.size.Y / 2 <= LobbyConfig.QUEUE_BEACON_HEIGHT_STUDS,
		`blade top {blade.offset.Y + blade.size.Y / 2} under QUEUE_BEACON_HEIGHT_STUDS`
	)
end)

test(
	"ghost preview never z-fights: GhostPlan(next) shares no overlapping vertical plane with the built tier",
	function()
		-- New pin (R5 WP2.4, §5): nesting is pinned above; this is the direct
		-- proof for both upgrade steps. A pair z-fights when two faces are
		-- coplanar (within 0.05) AND their rectangles overlap, so every ghost
		-- X/Z face is checked against every built architecture face (rotated
		-- planks have no axis-aligned faces and yard dressing <= 2.5 tall sits
		-- below the ghost read — both exempt; Y faces are exempt because
		-- grounded parts legally share the pad plane).
		for tier = 1, 2 do
			local ghost = (HousePlan :: any).GhostPlan(tier + 1) :: { Part }
			expect.ok(#ghost > 0, `tier {tier + 1} ghost plan is non-empty`)
			expect.ok(
				rawequal(ghost, (HousePlan :: any).GhostPlan(tier + 1)),
				`tier {tier + 1} ghost plan memoized (D2)`
			)
			for ghostIndex, ghostPart in ghost do
				local gMinX, gMaxX, gMinY, gMaxY, gMinZ, gMaxZ = rotatedAabb(ghostPart)
				for builtIndex, builtPart in partsOf(tier, SHELL_LISTS) do
					local bMinX, bMaxX, bMinY, bMaxY, bMinZ, bMaxZ = rotatedAabb(builtPart)
					if builtPart.orientation ~= nil or bMaxY - bMinY <= 2.5 then
						continue
					end
					local yOverlap = math.min(gMaxY, bMaxY) - math.max(gMinY, bMinY) > 0.01
					local xOverlap = math.min(gMaxX, bMaxX) - math.max(gMinX, bMinX) > 0.01
					local zOverlap = math.min(gMaxZ, bMaxZ) - math.max(gMinZ, bMinZ) > 0.01
					if yOverlap and zOverlap then
						for _, ghostFace in { gMinX, gMaxX } do
							for _, builtFace in { bMinX, bMaxX } do
								expect.ok(
									math.abs(ghostFace - builtFace) > 0.05,
									`ghost {tier + 1} part {ghostIndex} X-plane clear of tier {tier} part {builtIndex}`
								)
							end
						end
					end
					if yOverlap and xOverlap then
						for _, ghostFace in { gMinZ, gMaxZ } do
							for _, builtFace in { bMinZ, bMaxZ } do
								expect.ok(
									math.abs(ghostFace - builtFace) > 0.05,
									`ghost {tier + 1} part {ghostIndex} Z-plane clear of tier {tier} part {builtIndex}`
								)
							end
						end
					end
				end
			end
		end
	end
)

test("R5 tombstones: HOUSING_TIER_SLOTS 12/24/60 and STEP_PLATE.LOCAL_Z -29.5 untouched", function()
	-- New pin (R5 WP2.4, plan D5/D9): the display contract and the street
	-- plate are FROZEN by this round — a redesign that nudges either one is
	-- a contract break, not a tuning choice.
	expect.deepEq(GameConstants.HOUSING_TIER_SLOTS, { 12, 24, 60 }, "HOUSING_TIER_SLOTS frozen (D9)")
	expect.eq((LobbyConfig :: any).STEP_PLATE.LOCAL_Z, -29.5, "step plate of record DOES NOT MOVE (D5)")
end)

--------------------------------------------------------------------------------
-- SOP §10 — part budgets
--------------------------------------------------------------------------------

test("vacant lot estimate <= 60 (lot + sign + 8 podiums)", function()
	expect.eq(LobbyConfig.PART_BUDGET_VACANT_LOT, 60, "SOP cap of record")
	expect.ok(
		HousePlan.EstimateParts(0) <= LobbyConfig.PART_BUDGET_VACANT_LOT,
		`vacant estimate {HousePlan.EstimateParts(0)} inside 60`
	)
end)

test("R5 tiered house caps: whole-lot EstimateParts inside 160 / 240 / 450 per tier", function()
	-- Pin succession (Addendum 4 §6, plan D4): predecessor was the flat
	-- per-shell 400 cap (key deleted in WP1.2). The tiered caps bind the
	-- WHOLE LOT — shell + podiums + sign allowance — which is exactly what
	-- EstimateParts(tier) promises.
	local caps = (LobbyConfig :: any).PART_BUDGET_HOUSE_BY_TIER
	expect.ok(type(caps) == "table", "PART_BUDGET_HOUSE_BY_TIER table of record exists (Addendum 4 §6)")
	expect.ok(table.isfrozen(caps), "tier caps ship frozen (plan D4)")
	expect.eq(#caps, 3, "one cap per owned tier")
	expect.eq(caps[1], 160, "tier 1 cap of record")
	expect.eq(caps[2], 240, "tier 2 cap of record")
	expect.eq(caps[3], 450, "tier 3 cap of record")
	for tier = 1, 3 do
		expect.ok(
			HousePlan.EstimateParts(tier) <= caps[tier],
			`tier {tier} whole-lot estimate {HousePlan.EstimateParts(tier)} inside the {caps[tier]} cap`
		)
	end
	expect.ok(
		HousePlan.EstimateParts(3) <= GameConstants.PART_BUDGET_LOT,
		`mansion lot total {HousePlan.EstimateParts(3)} inside PART_BUDGET_LOT`
	)
	-- The monotonicity pin survives R5 (plan D4): every upgrade adds parts.
	for tier = 1, 3 do
		expect.ok(
			HousePlan.EstimateParts(tier) > HousePlan.EstimateParts(tier - 1),
			`tier {tier} estimate grows with the upgrade`
		)
	end
end)

test("worst case: street 4000 + 20 lots at the tier-3 cap = 13000 inside the 20k lobby total", function()
	-- R5 re-pin (Addendum 4 §6; predecessors: the 15000 total / 3000 street
	-- caps of the base SOP §10). Raise justification of record: 20 lots x
	-- all-mansion x 450 (whole-lot cap) = 9000 house parts; + street and
	-- landmarks <= 4000 -> worst case 13000. 20000 is the conservative end
	-- of mobile guidance (20-30k has been shown viable; we stay under 20k);
	-- typical mixed-tier lobbies land around 8-10k.
	expect.eq(LobbyConfig.PART_BUDGET_LOBBY_TOTAL, 20000, "R5 lobby total of record")
	expect.eq(LobbyConfig.PART_BUDGET_STREET_AND_LANDMARKS, 4000, "R5 street/landmark cap of record")

	-- As planned: the shells this module actually describes.
	local planned = LobbyConfig.PART_BUDGET_STREET_AND_LANDMARKS
		+ GameConstants.HUB_DISPLAY_STATION_COUNT * HousePlan.EstimateParts(3)
	expect.ok(planned <= LobbyConfig.PART_BUDGET_LOBBY_TOTAL, `planned worst case {planned} inside 20000`)

	-- At the caps: every lot grown to the full tier-3 whole-lot allowance
	-- (podiums and sign INSIDE the cap now — no separate per-lot adders).
	local caps = (LobbyConfig :: any).PART_BUDGET_HOUSE_BY_TIER
	local atCaps = LobbyConfig.PART_BUDGET_STREET_AND_LANDMARKS + GameConstants.HUB_DISPLAY_STATION_COUNT * caps[3]
	expect.eq(atCaps, 13000, "at-caps worst case of record: 4000 + 20 x 450")
	expect.ok(atCaps <= LobbyConfig.PART_BUDGET_LOBBY_TOTAL, `cap-level worst case {atCaps} inside 20000`)
end)

--------------------------------------------------------------------------------
-- SOP §2.6 — light budget arithmetic
--------------------------------------------------------------------------------

test("22 lamps + 20 lot washes + 8 feature lights fit the 50-light budget", function()
	expect.eq(LobbyConfig.LIGHT_BUDGET, 50, "light budget of record")
	expect.eq(LobbyConfig.STREET_LAMP.COUNT, 22, "street lamp count of record")
	-- R2 feature census of record (Addendum 1 Changes 5/8; WP1.6 ledger):
	-- FactoryBuilder marquee x2, ShopBuilder neon trim x1, QueuePadBuilder
	-- queue-pad pillar x1, ComingSoonBuilder uplight x1, WallBuilder
	-- SurfaceLight x1, PlazaBuilder UnboxStage spotlight x1, and PlazaBuilder
	-- swap-meet stall light x1 — the fountain PointLight's reassigned slot
	-- (Change 8 removal funds the Change 5 "further illuminated" swap, the
	-- only legal real-light path under a full budget). Every one is made via
	-- PartKit.MakeSpot/MakePoint or hand-registered (WallBuilder), so
	-- HubService's LightBudget assert sees this exact census at boot.
	local featureLights = 8
	local lotWashes = GameConstants.HUB_DISPLAY_STATION_COUNT -- ONE wash per lot, never per podium
	local total = LobbyConfig.STREET_LAMP.COUNT + lotWashes + featureLights
	expect.ok(total <= LobbyConfig.LIGHT_BUDGET, `light arithmetic {total} inside the budget`)
	-- As-built sits EXACTLY at budget — zero headroom. Any new lobby light
	-- must retire one first (or this pin and the runtime assert both trip).
	expect.eq(total, LobbyConfig.LIGHT_BUDGET, "as-built light census is exactly at budget")
end)

--------------------------------------------------------------------------------
-- Addendum 1 (R2) — Changes 1/3/8 lot & hero blocks (WP1.6 reconciliation).
-- The budget is FULL at 50/50, so every new R2 glow block must be Neon-only
-- arithmetic: zero Light-instance tunables anywhere in the new config.
--------------------------------------------------------------------------------

test("R2/R3 lobby glow blocks are Neon-only (zero Light implications); fountain config gone", function()
	local cfg = LobbyConfig :: any
	-- Change 8: the fountain block (the one config block that DID carry Light
	-- tunables) is removed in config/world lockstep; its PointLight slot is
	-- the swap-meet feature light in the census above.
	expect.ok(cfg.FOUNTAIN == nil, "LobbyConfig.FOUNTAIN removed (Addendum 1 Change 8)")
	-- Changes 1/3: beacon, trim, and hero FX are Neon material only. No key
	-- in these blocks may describe a Light instance (the removed fountain
	-- shape was LIGHT_RANGE/LIGHT_BRIGHTNESS/LIGHT_COLOR). Addendum 2 (R3)
	-- adds STEP_PLATE (Neon border trim) and BIKE (one Neon strip) under the
	-- same rule — the budget is still FULL at exactly 50.
	for _, blockName in { "LOT_BEACON", "LOT_TRIM", "HERO", "STEP_PLATE", "BIKE" } do
		local block = cfg[blockName]
		expect.ok(type(block) == "table", `LobbyConfig.{blockName} block of record exists`)
		for key in block do
			expect.ok(
				string.find(key, "^LIGHT") == nil,
				`{blockName}.{key} must not smuggle a Light tunable (budget full at 50)`
			)
			expect.ok(string.find(key, "BRIGHTNESS") == nil, `{blockName}.{key} has no brightness — Neon glow only`)
		end
	end
end)

test("claimed wash cone lights the whole lot, bleeds only into the 8-stud gap", function()
	local cfg = LobbyConfig :: any
	local claimed = cfg.LOT_WASH_CLAIMED
	expect.ok(type(claimed) == "table", "LobbyConfig.LOT_WASH_CLAIMED block of record exists")
	-- Change 1 cone math of record: the wash mounts at 18 studs
	-- (StreetBuilder WASH_MOUNT_HEIGHT, line 110). Claimed Angle 114 ->
	-- half-angle 57 -> ground radius 18 * tan(57°) ≈ 27.7: reaches the
	-- 55-stud-axis edge (half-axis 27.5) but stays inside the 8-stud gap —
	-- never a neighbor's lawn.
	local WASH_MOUNT_HEIGHT = 18 -- StreetBuilder.luau mount of record
	local groundRadius = WASH_MOUNT_HEIGHT * math.tan(math.rad(claimed.ANGLE / 2))
	local lotHalfAxis = LobbyConfig.LOT_DEPTH_STUDS / 2 -- 27.5
	expect.ok(groundRadius >= lotHalfAxis, `ground radius {groundRadius} reaches the lot edge {lotHalfAxis}`)
	expect.ok(
		groundRadius <= lotHalfAxis + 0.5,
		`ground radius {groundRadius} spills <= 0.5 studs past the lot edge (no neighbor bleed)`
	)
	-- Lot beacons cap at 35 studs; the 60-stud queue beacon stays the
	-- tallest landmark on the skyline (Change 1 hard cap).
	expect.ok(cfg.LOT_BEACON.HEIGHT <= 35, "lot beacon height under the 35-stud hard cap")
	expect.ok(35 < LobbyConfig.QUEUE_BEACON_HEIGHT_STUDS, "queue beacon (60) remains the tallest landmark")
end)

--------------------------------------------------------------------------------
-- Addendum 2 (R3) — step plate, bike, and hero-label-prune pins (WP1.7).
-- STEP_PLATE and BIKE are the constants of record shared by the server
-- builders (StreetBuilder, BikeService) and the client consumers
-- (HousePreviewController predicate, InputController formula) — these pins
-- hold the contract still on both sides.
--------------------------------------------------------------------------------

test("STEP_PLATE geometry: 4x4 thumbstick floor, proud step, fully street-side of the lot line", function()
	local plate = (LobbyConfig :: any).STEP_PLATE
	expect.ok(type(plate) == "table", "LobbyConfig.STEP_PLATE block of record exists (Addendum 2 R3-3)")
	-- Never below 4x4: DynamicThumbstick users cannot hold a sub-4-stud target.
	expect.ok(plate.WIDTH >= 4, `plate width {plate.WIDTH} at or above the 4-stud thumbstick floor`)
	expect.ok(plate.DEPTH >= 4, `plate depth {plate.DEPTH} at or above the 4-stud thumbstick floor`)
	-- A literal step: 0.2-0.35 studs proud of the paving, walkable at base speed.
	expect.ok(
		plate.PROUD_STUDS >= 0.2 and plate.PROUD_STUDS <= 0.35,
		`PROUD_STUDS {plate.PROUD_STUDS} inside the [0.2, 0.35] step-lip band`
	)
	-- Interior-veto compatibility invariant: the plate's lot-side edge may
	-- kiss but never cross the lot front line (plot-local -LOT_DEPTH/2, -Z
	-- streetward), so the 45x55-footprint interior veto can never fight the
	-- stand-on-plate predicate — "never inside the lot" stays contradiction-free.
	expect.ok(
		plate.LOCAL_Z + plate.DEPTH / 2 <= -LobbyConfig.LOT_DEPTH_STUDS / 2,
		`plate lot-side edge {plate.LOCAL_Z + plate.DEPTH / 2} fully street-side of the lot line {-LobbyConfig.LOT_DEPTH_STUDS / 2}`
	)
end)

test("STEP_PLATE hysteresis: exit box strictly larger than enter box; dwell >= 2 polls", function()
	local plate = (LobbyConfig :: any).STEP_PLATE
	-- Spatial hysteresis: the ghost only flips OFF outside the larger exit
	-- box, so thumbstick wobble at the plate edge cannot flicker it.
	expect.ok(
		plate.EXIT_HALF_X > plate.ENTER_HALF_X,
		`exit half-X {plate.EXIT_HALF_X} strictly larger than enter half-X {plate.ENTER_HALF_X}`
	)
	expect.ok(
		plate.EXIT_HALF_Z > plate.ENTER_HALF_Z,
		`exit half-Z {plate.EXIT_HALF_Z} strictly larger than enter half-Z {plate.ENTER_HALF_Z}`
	)
	-- Temporal hysteresis: >= 2 consecutive polls (~0.2 s at the 10 Hz poll)
	-- before SHOW and before HIDE filters the walk-across flash both ways.
	expect.ok(plate.DWELL_POLLS >= 2, `DWELL_POLLS {plate.DWELL_POLLS} >= 2`)
end)

test("STEP_PLATE border is the ghost blue (140, 205, 255) — step and ghost read as one system", function()
	local plate = (LobbyConfig :: any).STEP_PLATE
	expect.ok(type(plate.BORDER_COLOR) == "table", "BORDER_COLOR is an RGB table of record")
	expect.eq(plate.BORDER_COLOR.R, 140, "border R == COLOR_GHOST R")
	expect.eq(plate.BORDER_COLOR.G, 205, "border G == COLOR_GHOST G")
	expect.eq(plate.BORDER_COLOR.B, 255, "border B == COLOR_GHOST B")
end)

test("BIKE pins: 2.2x base above sprint AND above the shift validator cap (structural safety)", function()
	local bike = (LobbyConfig :: any).BIKE
	expect.ok(type(bike) == "table", "LobbyConfig.BIKE block of record exists (Addendum 2 R3-5)")
	local mult = (GameConstants :: any).BIKE_SPEED_MULT
	expect.eq(mult, 2.2, "GameConstants.BIKE_SPEED_MULT of record (Addendum 3 R4-3)")
	local bikeSpeed = GameConstants.WALKSPEED_BASE * mult
	-- Worth mounting: faster than sprint. Precedence is max(bike path, sprint
	-- path) in BOTH WalkSpeed owners — the multiplier never stacks with sprint.
	expect.ok(
		bikeSpeed > GameConstants.SPRINT_SPEED,
		`bike speed {bikeSpeed} above SPRINT_SPEED {GameConstants.SPRINT_SPEED}`
	)
	-- R4-3 INVERSION of the old numeric-cap pin: 30.8 studs/s deliberately
	-- EXCEEDS the SPRINT_SPEED * 1.35 anti-speed cap (27). Recorded
	-- justification: the shift validator iterates playerToSession floor
	-- participants only (ShiftService.luau:720), where BikeActive is
	-- structurally false via the pre-pivot ForceDismount — a bike never
	-- exists where the validator runs. Any future "validate the lobby too"
	-- change MUST add a BikeActive allowance ≈ WALKSPEED_BASE *
	-- BIKE_SPEED_MULT * 1.15 ≈ 35, or riders insta-flag.
	expect.ok(
		bikeSpeed > GameConstants.SPRINT_SPEED * 1.35,
		`bike speed {bikeSpeed} above the shift validator cap {GameConstants.SPRINT_SPEED * 1.35} (structural safety of record)`
	)
	-- Ceiling of record: under the ~2.5x "reads as exploit speed" threshold.
	expect.ok(mult < 2.5, `BIKE_SPEED_MULT {mult} under the 2.5x exploit-read ceiling`)
	-- Mount grants are lobby-fenced by one radius check of record.
	expect.eq(bike.LOBBY_RADIUS_STUDS, 400, "bike lobby radius of record")
end)

test("R3-2 prune: HERO label keys are GONE, not dead-documented (config/world lockstep)", function()
	local hero = (LobbyConfig :: any).HERO
	expect.ok(hero.LABEL_HEIGHT_ABOVE == nil, "HERO.LABEL_HEIGHT_ABOVE pruned (Addendum 2 R3-2)")
	expect.ok(hero.LABEL_MAX_DISTANCE == nil, "HERO.LABEL_MAX_DISTANCE pruned (Addendum 2 R3-2)")
end)

--------------------------------------------------------------------------------
-- WP4.5 — as-built reconciliation (Wave 2/3 builders, re-derived 2026-06-11).
-- Pure-arithmetic mirrors of the shipped builder code; every constant cites
-- the function that owns it. Asserted AGAINST the HousePlan allowances so the
-- envelope EstimateParts() promises always covers what actually gets built.
--------------------------------------------------------------------------------

-- ShelfRoomBuilder.buildPodiums: plinth + Neon ring + invisible query pad.
local AS_BUILT_PODIUM_PARTS = 3
-- ShelfRoomBuilder.buildVacantDressing: 5 fence rails + 4 fence posts +
-- porch-lamp post + Neon bulb (NO Light instance) = 11; buildSign: post +
-- plate = 2 (R5 moves the FOR SALE sign to the apron seat at (-16, -25)
-- with the 15-degree yaw — same part count, new transform).
local AS_BUILT_VACANT_DRESSING = 11 + 2
-- R5 re-derivation (WP2.4; predecessor census: 4 fixture parts + 1
-- MansionTrim). ShelfRoomBuilder.rebuildOwned fixtures of record: the §1.0
-- owner sign is a 6-part assembly at (-16, -25) yawed 15 degrees toward the
-- street + EntranceAnchor + VisitTrigger = 8; MansionTrim died with the
-- WedgePart emission path (WP2.2).
local AS_BUILT_OWNED_FIXTURES = 6 + 2

test("as-built podium is exactly the 3 parts the budget math charges", function()
	expect.eq(HousePlan.PARTS_PER_PODIUM, AS_BUILT_PODIUM_PARTS, "plinth + ring + pad of record")
end)

test("as-built vacant lot (37 parts) sits inside its allowance and the 60 cap", function()
	expect.ok(
		AS_BUILT_VACANT_DRESSING <= HousePlan.VACANT_DRESSING_PART_ALLOWANCE,
		`dressing {AS_BUILT_VACANT_DRESSING} inside the {HousePlan.VACANT_DRESSING_PART_ALLOWANCE} allowance`
	)
	local vacantTotal = AS_BUILT_VACANT_DRESSING + GameConstants.SHELF_BASE_SLOTS * AS_BUILT_PODIUM_PARTS
	expect.eq(vacantTotal, 37, "as-built vacant lot count of record")
	expect.ok(vacantTotal <= HousePlan.EstimateParts(0), "envelope covers the as-built vacant lot")
	expect.ok(vacantTotal <= LobbyConfig.PART_BUDGET_VACANT_LOT, "as-built vacant lot inside the SOP 60 cap")
end)

test("as-built owned-lot fixtures and shells stay inside every envelope", function()
	-- R5 re-pin (WP2.4, plan D4/D5; predecessor budgeted 4 fixtures + 1
	-- MansionTrim against the old 6-part allowance): the allowance of record
	-- is 10, the as-built census is 8 (6-part sign + anchor + trigger).
	expect.eq(HousePlan.OWNER_SIGN_PART_ALLOWANCE, 10, "owner-sign allowance of record (D4: 6 -> 10)")
	expect.ok(
		AS_BUILT_OWNED_FIXTURES <= HousePlan.OWNER_SIGN_PART_ALLOWANCE,
		"6-part sign + anchor + trigger inside the sign allowance"
	)
	-- R5: the shell-only reference bounds against the tier-3 WHOLE-LOT cap
	-- (predecessor: the flat per-shell 400 cap) — shell <= whole lot is the
	-- conservative direction, so the tripwire only got tighter.
	expect.ok(
		HousePlan.EstimateShellParts(3) <= (LobbyConfig :: any).PART_BUDGET_HOUSE_BY_TIER[3],
		`as-built mansion shell {HousePlan.EstimateShellParts(3)} inside the tier-3 whole-lot cap`
	)
	for tier = 1, 3 do
		local asBuilt = HousePlan.EstimateShellParts(tier)
			+ HousePlan.SlotCount(tier) * AS_BUILT_PODIUM_PARTS
			+ AS_BUILT_OWNED_FIXTURES
		expect.ok(
			asBuilt <= HousePlan.EstimateParts(tier),
			`tier {tier}: as-built {asBuilt} inside the EstimateParts envelope {HousePlan.EstimateParts(tier)}`
		)
		expect.ok(asBuilt <= GameConstants.PART_BUDGET_LOT, `tier {tier}: as-built inside PART_BUDGET_LOT`)
	end
end)

test("as-built plaza particles: 3 hero sparkle emitters inside the 100/s budget", function()
	-- Change 8 retired the fountain jets (25 + 12 = 37/s freed); Change 3's
	-- hero sparkles inherit that headroom — 3 heroes x SPARKLE_RATE (~30/s)
	-- are the only lobby plaza emitter site after R2.
	local plazaRate = 3 * (LobbyConfig :: any).HERO.SPARKLE_RATE
	expect.ok(
		plazaRate <= LobbyConfig.PLAZA_PARTICLE_RATE_BUDGET,
		`combined plaza emitter rate {plazaRate} inside {LobbyConfig.PLAZA_PARTICLE_RATE_BUDGET}/s`
	)
end)

--------------------------------------------------------------------------------
-- Addendum 1 Change 6 — metronome dispatch constants of record (WP1.6)
--------------------------------------------------------------------------------

test("DISPATCH pins: 45 s cycle == INTERMISSION_SECONDS; bins 4, freeze 3, AFK 120, slots 5 @ 2000", function()
	local dispatch = (LobbyConfig :: any).DISPATCH
	expect.ok(type(dispatch) == "table", "LobbyConfig.DISPATCH block of record exists")
	expect.eq(dispatch.CYCLE_SECONDS, 45, "verbatim constant 45 s loop")
	expect.eq(dispatch.CYCLE_SECONDS, GameConstants.INTERMISSION_SECONDS, "single 45 s source of record")
	expect.eq(dispatch.BIN_SIZE, 4, "dispatch bins of up to 4 occupants")
	expect.eq(dispatch.FREEZE_SECONDS, 3, "T-3 snapshot freeze")
	expect.eq(dispatch.AFK_EXCLUDE_SECONDS, 120, "pad AFK exclusion window")
	expect.eq(dispatch.SLOT_COUNT, 5, "5 fixed concurrent floor slots")
	expect.eq(dispatch.SLOT_PITCH_STUDS, 2000, "2000-stud slot pitch")
end)

--------------------------------------------------------------------------------
-- Addendum 1 Change 6 — surviving queue keys pin to the metronome (WP6.3).
-- The Wave-5 cutover retired the old pad FSM; its full-clamp/T-1-lock/re-arm
-- pins (5/1/2) retired with the dead queue keys (WP6.2) in favor of the
-- DISPATCH pins above (perpetual epoch needs no clamp or lock). The keys that
-- survive (QUEUE_SECONDS, QUEUE_CAPACITY) must agree with DISPATCH exactly —
-- one 45 s cycle and one bin size of record, never two sources.
--------------------------------------------------------------------------------

test("surviving queue keys == metronome constants: 45 s cycle, capacity 4 == bin size", function()
	local dispatch = (LobbyConfig :: any).DISPATCH
	expect.eq(LobbyConfig.QUEUE_SECONDS, 45, "verbatim constant 45 s loop")
	expect.eq(LobbyConfig.QUEUE_SECONDS, GameConstants.INTERMISSION_SECONDS, "single 45 s source of record")
	expect.eq(LobbyConfig.QUEUE_SECONDS, dispatch.CYCLE_SECONDS, "pad timer IS the dispatch cycle")
	expect.eq(LobbyConfig.QUEUE_CAPACITY, 4, "dispatch groups of up to 4")
	expect.eq(LobbyConfig.QUEUE_CAPACITY, dispatch.BIN_SIZE, "roster capacity IS the dispatch bin size")
end)

--------------------------------------------------------------------------------
-- SOP §11.1 — billboard distances of record
--------------------------------------------------------------------------------

test("billboard MaxDistances 400 / 250 / 80", function()
	expect.eq(LobbyConfig.BILLBOARD_MAX_DISTANCE.SIGN, 400, "building/lot signs")
	expect.eq(LobbyConfig.BILLBOARD_MAX_DISTANCE.CLOCK_IN, 250, "clock-in billboard")
	expect.eq(LobbyConfig.BILLBOARD_MAX_DISTANCE.PODIUM, 80, "podium labels")
end)

return { name = "lobby budget (HousePlan + LobbyConfig)", tests = tests }
