--!strict
-- R5 stair-core suite (LOBBY_BUILD_PLAN_R5 WP1.3; LOBBY_SOP_ADDENDUM_4 §2 —
-- the binding stair specification). Mechanizes AC-R5.3 as pure math over
-- HousePlanStairs.Generate output, driven with the EXACT per-tier core specs
-- of record (§1.1-1.3 core positions, §2.5 worked table + tier mapping). No
-- Roblox instances and no HousePlan dependency: HousePlan COMPOSES this same
-- generator in Wave 2, and lobby_budget (WP2.4) pins that composition.
--
-- The bug this suite tombstones (Addendum 4 root cause): every floor
-- transition reused ONE full-pitch WedgePart envelope at the identical XZ,
-- so transition N+1's solid flat-bottomed box sat directly on transition N's
-- arrival point — zero clearance, roof unreachable. Three pins make the
-- whole class impossible:
--   1. every flight is a plank <= 1.2 thick (a 10-stud envelope CANNOT pass);
--   2. flight A and flight B are disjoint in X by >= 7 center-to-center
--      (different bays, spine between) — arrival never under departure;
--   3. stacked same-bay flights keep >= 9 studs vertical at EVERY tread
--      point (pitch 10 - plank 1, the §2.5 no-overlap proof, mechanized).
--
-- Walk-chain scope: door -> stoop -> F1 is HousePlan massing (Wave 2; WP2.4
-- pins it). This suite proves the F1 -> roof chain through the core with
-- ZERO vertical discontinuity between consecutive walk surfaces.

local LobbyConfig = require("../../src/shared/Config/LobbyConfig")
local StairCore = require("../../src/shared/Logic/HousePlanStairs")
local expect = require("../expect")

local tests = {}
local function test(name: string, fn: () -> ())
	table.insert(tests, { name = name, fn = fn })
end

--------------------------------------------------------------------------------
-- Numbers of record (Addendum 4 §2.3 — binding table)
--------------------------------------------------------------------------------

local PITCH = 10 -- storey pitch of record: 9 wall + 1 slab (§2.3; cross-pinned below)
local RISE = PITCH / 2 -- rise per flight: clean half-pitch (§2.3)
local RUN = 8 -- run per flight (§2.3)
-- Slope and plank length are DERIVED, never hand-typed (binding decision D2):
local SLOPE_DEG = math.deg(math.atan(RISE / RUN)) -- ~32.0 deg, inside the 35 comfort cap
local PLANK_LENGTH = math.sqrt(RUN ^ 2 + RISE ^ 2)
local FLIGHT_WIDTH = 6
local PLANK_THIN_MAX = 1.2 -- AC-R5.3: anything thicker reads as an envelope -> FAILURE
local BAY_WIDTH = 6
local SPINE_WIDTH = 1
local CORE_WIDTH = 13 -- west bay 6 + spine 1 + east bay 6 (§2.1)
local CORE_DEPTH = 14 -- run 8 + half-landing 6 (§2.1/§2.3)
local LANDING_DEPTH = 6
local HEADROOM_MIN = 8 -- AC-R5.3 floor; the template delivers 9.0 (§2.3)
local STACK_CLEAR = PITCH - 1 -- 9.0 = pitch minus the 1-thick plank (§2.5 proof)
local BULKHEAD_WALL_HEIGHT = 8 -- bulkhead walls roofTop..+8, cap +8..+9 (§2.5)
local DOOR_HEIGHT = 7 -- bulkhead/terrace doors are 6w x 7h (§2.3)
local KEEP_CLEAR_DEPTH = 6 -- arrival pad / run-bottom strip depth (§2.3)

type Rgb = { R: number, G: number, B: number }
type Dim3 = { X: number, Y: number, Z: number }
type StairPart = { size: Dim3, offset: Dim3, orientation: Dim3?, color: Rgb? }
type Rect = { minX: number, maxX: number, minZ: number, maxZ: number }
type CoreResult = {
	stairs: { StairPart },
	walls: { StairPart },
	slabs: { StairPart },
	neon: { StairPart },
	cutout: Rect,
	keepClears: { Rect },
}

type TierSpec = {
	tier: number,
	coreMinX: number,
	coreMaxX: number,
	coreMinZ: number,
	coreMaxZ: number,
	mouthZ: number,
	ffl1: number,
	floors: number,
}

-- Core rectangles of record (§1.1-1.3 "Stair core position"; mouth plane =
-- core front; FFL1 1/3/3 per D3 — cross-pinned against LobbyConfig below).
local TIER_SPECS: { TierSpec } = {
	{ tier = 1, coreMinX = 2.5, coreMaxX = 15.5, coreMinZ = 0.5, coreMaxZ = 14.5, mouthZ = 0.5, ffl1 = 1, floors = 1 },
	{ tier = 2, coreMinX = 4.5, coreMaxX = 17.5, coreMinZ = 6, coreMaxZ = 20, mouthZ = 6, ffl1 = 3, floors = 2 },
	{
		tier = 3,
		coreMinX = 6.5,
		coreMaxX = 19.5,
		coreMinZ = 10.5,
		coreMaxZ = 24.5,
		mouthZ = 10.5,
		ffl1 = 3,
		floors = 5,
	},
}

-- High-V accent fixtures in the frozen raw-RGB shape of record (D8). The
-- generator must pass these tables through UNTOUCHED: raw-table -> Color3
-- property assignment is the recurring boot-crash class, so Color3.fromRGB
-- happens at APPLY time (builder/ghost) only — never in plan data.
local function accentFixtures(count: number): { Rgb }
	local list: { Rgb } = {}
	for index = 1, count do
		list[index] = table.freeze({ R = 255, G = 190 + index * 5, B = 80 + index * 10 }) :: Rgb
	end
	return table.freeze(list) :: { Rgb }
end

local cache: { [number]: CoreResult } = {}
local function generated(ts: TierSpec): CoreResult
	local hit = cache[ts.tier]
	if hit ~= nil then
		return hit
	end
	local result = (StairCore :: any).Generate({
		coreMinX = ts.coreMinX,
		coreMaxX = ts.coreMaxX,
		coreMinZ = ts.coreMinZ,
		coreMaxZ = ts.coreMaxZ,
		mouthZ = ts.mouthZ,
		ffl1 = ts.ffl1,
		floors = ts.floors,
		pitch = PITCH,
		accentColors = accentFixtures(ts.floors + 1),
	}) :: CoreResult
	cache[ts.tier] = result
	return result
end

--------------------------------------------------------------------------------
-- Geometry helpers
--------------------------------------------------------------------------------

local function westCenter(ts: TierSpec): number
	return ts.coreMinX + BAY_WIDTH / 2
end

local function eastCenter(ts: TierSpec): number
	return ts.coreMaxX - BAY_WIDTH / 2
end

local function floorTop(ts: TierSpec, floor: number): number
	return ts.ffl1 + (floor - 1) * PITCH
end

local function roofTop(ts: TierSpec): number
	return ts.ffl1 + ts.floors * PITCH
end

-- Inclined-plank surface math. The builder applies
-- CFrame.new(offset) * CFrame.Angles(rad(X), 0, 0) (binding decision D2); a
-- right-handed rotation about +X lifts the part's -Z end by sin(X) * L/2, so
-- the plank's walk plane (centerline) at depth z is
-- offset.Y + (offset.Z - z) * tan(X). Positive X therefore ascends toward -Z
-- (flight B, landing -> mouth) and negative X ascends toward +Z (flight A,
-- mouth -> landing).
local function orientationOf(plank: StairPart): Dim3
	local orientation = plank.orientation
	assert(orientation ~= nil, "plank helpers require a rotated stair part")
	return orientation
end

local function centerlineY(plank: StairPart, z: number): number
	return plank.offset.Y + (plank.offset.Z - z) * math.tan(math.rad(orientationOf(plank).X))
end

local function runSpan(plank: StairPart): (number, number)
	local halfRun = plank.size.Z * math.abs(math.cos(math.rad(orientationOf(plank).X))) / 2
	return plank.offset.Z - halfRun, plank.offset.Z + halfRun
end

-- Closed-form rotated AABB for X-axis orientation (binding decision D1):
-- aabbY = sizeY*cos + sizeZ*sin, aabbZ = sizeZ*cos + sizeY*sin, X unchanged.
local function rotatedAabb(part: StairPart): (number, number, number, number, number, number)
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

-- Stairs split into up-flight A (east bay), up-flight B (west bay), and
-- half-landings, each sorted ground-up. Bay assignment is §2.3-binding:
-- facing the core (looking +Z), east bay departs, west bay arrives.
local function stairsSplit(ts: TierSpec): ({ StairPart }, { StairPart }, { StairPart })
	local east: { StairPart } = {}
	local west: { StairPart } = {}
	local landings: { StairPart } = {}
	for _, part in generated(ts).stairs do
		if part.orientation == nil then
			table.insert(landings, part)
		elseif math.abs(part.offset.X - eastCenter(ts)) <= 0.01 then
			table.insert(east, part)
		elseif math.abs(part.offset.X - westCenter(ts)) <= 0.01 then
			table.insert(west, part)
		else
			error(`tier {ts.tier}: rotated stair part at x={part.offset.X} sits in neither bay`)
		end
	end
	local function byY(a: StairPart, b: StairPart): boolean
		return a.offset.Y < b.offset.Y
	end
	table.sort(east, byY)
	table.sort(west, byY)
	table.sort(landings, byY)
	return east, west, landings
end

-- Tread sample offsets along the 8-stud run (quarter-stud in from each end,
-- half-stud pitch — every tread point of the binding walk surface).
local TREAD_STEPS: { number } = {}
do
	local t = 0.25
	while t < RUN do
		table.insert(TREAD_STEPS, t)
		t += 0.5
	end
end

--------------------------------------------------------------------------------
-- Spec cross-pin
--------------------------------------------------------------------------------

test("spec inputs of record match LobbyConfig.HOUSE: pitch 10 = 9 + 1, FFL1 1/3/3, 13 x 14 cores", function()
	local house = (LobbyConfig :: any).HOUSE
	expect.ok(type(house) == "table", "LobbyConfig.HOUSE block of record exists (WP1.2, plan D3)")
	expect.eq(house.FLOOR_PITCH_STUDS, PITCH, "storey pitch of record")
	expect.eq(house.WALL_HEIGHT_STUDS, 9, "wall height of record")
	expect.eq(house.SLAB_THICKNESS_STUDS, 1, "slab thickness of record")
	expect.eq(house.WALL_HEIGHT_STUDS + house.SLAB_THICKNESS_STUDS, PITCH, "pitch = wall + slab identity")
	for _, ts in TIER_SPECS do
		expect.eq(house.FFL1_BY_TIER[ts.tier], ts.ffl1, `tier {ts.tier} FFL1 of record`)
		expect.near(ts.coreMaxX - ts.coreMinX, CORE_WIDTH, 1e-9, `tier {ts.tier} core 13 wide`)
		expect.near(ts.coreMaxZ - ts.coreMinZ, CORE_DEPTH, 1e-9, `tier {ts.tier} core 14 deep`)
		expect.eq(ts.mouthZ, ts.coreMinZ, `tier {ts.tier} mouth plane is the core front`)
	end
end)

--------------------------------------------------------------------------------
-- Census & form
--------------------------------------------------------------------------------

test("census: exactly floors x (2 planks + 1 landing); only stairs carry orientation", function()
	for _, ts in TIER_SPECS do
		local result = generated(ts)
		local east, west, landings = stairsSplit(ts)
		expect.eq(#result.stairs, ts.floors * 3, `tier {ts.tier} stair list is floors x 3`)
		expect.eq(#east, ts.floors, `tier {ts.tier} one up-flight A per transition (east bay)`)
		expect.eq(#west, ts.floors, `tier {ts.tier} one up-flight B per transition (west bay)`)
		expect.eq(#landings, ts.floors, `tier {ts.tier} one half-landing per transition`)
		local categories: { [string]: { StairPart } } =
			{ walls = result.walls, slabs = result.slabs, neon = result.neon }
		for listName, list in categories do
			for index, part in list do
				expect.ok(
					part.orientation == nil,
					`tier {ts.tier} {listName}[{index}] is axis-aligned (D2: only stairs rotate)`
				)
			end
		end
	end
end)

test("AC-R5.3: every flight is a thin plank (<= 1.2) at full 6 width — envelopes extinct", function()
	for _, ts in TIER_SPECS do
		local east, west = stairsSplit(ts)
		for bayIndex, bay in { east, west } do
			for index, plank in bay do
				expect.ok(
					plank.size.Y <= PLANK_THIN_MAX,
					`tier {ts.tier} bay {bayIndex} plank {index} thickness {plank.size.Y} <= 1.2 (a full-pitch envelope FAILS here)`
				)
				expect.ok(
					plank.size.X >= FLIGHT_WIDTH,
					`tier {ts.tier} bay {bayIndex} plank {index} width {plank.size.X} >= 6 clear`
				)
			end
		end
	end
end)

test("orientation discipline: |X| = deg(atan(5/8)) +- 0.01 and <= 35; Y = Z = 0; signs by bay", function()
	for _, ts in TIER_SPECS do
		local east, west = stairsSplit(ts)
		for bayIndex, bay in { east, west } do
			for index, plank in bay do
				local orientation = orientationOf(plank)
				expect.near(
					math.abs(orientation.X),
					SLOPE_DEG,
					0.01,
					`tier {ts.tier} bay {bayIndex} plank {index} slope is exactly atan(rise/run)`
				)
				expect.ok(
					math.abs(orientation.X) <= 35,
					`tier {ts.tier} bay {bayIndex} plank {index} inside the 35-degree comfort cap`
				)
				expect.eq(orientation.Y, 0, `tier {ts.tier} bay {bayIndex} plank {index} never yaws (D2: X only)`)
				expect.eq(orientation.Z, 0, `tier {ts.tier} bay {bayIndex} plank {index} never rolls (D2: X only)`)
			end
		end
		-- Sign convention is forced by D2's apply rule (see centerline note):
		-- A ascends +Z (negative X), B ascends -Z (positive X). A flipped
		-- sign is a flipped flight — the walk chain below would also break.
		for index, plank in east do
			expect.ok(orientationOf(plank).X < 0, `tier {ts.tier} A{index} ascends +Z, so orientation.X is negative`)
		end
		for index, plank in west do
			expect.ok(orientationOf(plank).X > 0, `tier {ts.tier} B{index} ascends -Z, so orientation.X is positive`)
		end
	end
end)

--------------------------------------------------------------------------------
-- Flight & landing geometry (§2.5 worked table, generalized per tier)
--------------------------------------------------------------------------------

test("flight geometry: rise 5 / run 8 per flight, centers at the run midpoint of the right bay", function()
	for _, ts in TIER_SPECS do
		local east, west = stairsSplit(ts)
		for n = 1, ts.floors do
			local a, b = east[n], west[n]
			local thetaA = math.rad(math.abs(orientationOf(a).X))
			expect.near(a.size.Z, PLANK_LENGTH, 0.01, `tier {ts.tier} A{n} length sqrt(run^2 + rise^2)`)
			expect.near(a.size.Z * math.sin(thetaA), RISE, 0.01, `tier {ts.tier} A{n} rise is pitch/2`)
			expect.near(a.size.Z * math.cos(thetaA), RUN, 0.01, `tier {ts.tier} A{n} run is 8`)
			expect.near(a.offset.X, eastCenter(ts), 1e-3, `tier {ts.tier} A{n} centered in the east bay`)
			expect.near(a.offset.Y, floorTop(ts, n) + RISE / 2, 1e-3, `tier {ts.tier} A{n} at mid-rise`)
			expect.near(a.offset.Z, ts.mouthZ + RUN / 2, 1e-3, `tier {ts.tier} A{n} at the run midpoint`)

			local thetaB = math.rad(math.abs(orientationOf(b).X))
			expect.near(b.size.Z, PLANK_LENGTH, 0.01, `tier {ts.tier} B{n} length sqrt(run^2 + rise^2)`)
			expect.near(b.size.Z * math.sin(thetaB), RISE, 0.01, `tier {ts.tier} B{n} rise is pitch/2`)
			expect.near(b.size.Z * math.cos(thetaB), RUN, 0.01, `tier {ts.tier} B{n} run is 8`)
			expect.near(b.offset.X, westCenter(ts), 1e-3, `tier {ts.tier} B{n} centered in the west bay`)
			expect.near(b.offset.Y, floorTop(ts, n) + RISE + RISE / 2, 1e-3, `tier {ts.tier} B{n} at mid-rise`)
			expect.near(b.offset.Z, ts.mouthZ + RUN / 2, 1e-3, `tier {ts.tier} B{n} at the run midpoint`)
		end
	end
end)

test("half-landings 13 x 6 x 1 spanning the full core width, top at y0 + 5", function()
	for _, ts in TIER_SPECS do
		local _, _, landings = stairsSplit(ts)
		local coreCenterX = (ts.coreMinX + ts.coreMaxX) / 2
		for n, landing in landings do
			expect.near(landing.size.X, CORE_WIDTH, 1e-3, `tier {ts.tier} landing {n} spans the full 13 core width`)
			expect.near(landing.size.Y, 1, 1e-3, `tier {ts.tier} landing {n} is the 1-thick plate of record`)
			expect.near(landing.size.Z, LANDING_DEPTH, 1e-3, `tier {ts.tier} landing {n} is 6 deep (>= flight width)`)
			expect.near(landing.offset.X, coreCenterX, 1e-3, `tier {ts.tier} landing {n} centered across both bays`)
			expect.near(
				landing.offset.Y + landing.size.Y / 2,
				floorTop(ts, n) + RISE,
				1e-3,
				`tier {ts.tier} landing {n} top at y0 + 5`
			)
			expect.near(
				landing.offset.Z,
				ts.mouthZ + RUN + LANDING_DEPTH / 2,
				1e-3,
				`tier {ts.tier} landing {n} sits behind the flights (z mouth+8..mouth+14)`
			)
		end
	end
end)

--------------------------------------------------------------------------------
-- No-overlap proofs (§2.5, mechanized — the dead bug's tombstones)
--------------------------------------------------------------------------------

test("tombstone: every flight A vs every flight B disjoint in X by >= 7 centers with the spine between", function()
	-- The R4 bug of record: arrival point under the next departure envelope.
	-- Bays kill it structurally; this pin keeps the bays apart forever. All
	-- A x B pairs are checked, so B(n) vs A(n+1) is covered by construction.
	for _, ts in TIER_SPECS do
		local east, west = stairsSplit(ts)
		for n, a in east do
			for m, b in west do
				expect.ok(
					math.abs(a.offset.X - b.offset.X) >= BAY_WIDTH + SPINE_WIDTH - 1e-6,
					`tier {ts.tier} A{n}/B{m} centers >= 7 studs apart`
				)
				local aMinX = rotatedAabb(a)
				local _, bMaxX = rotatedAabb(b)
				expect.ok(
					aMinX - bMaxX >= SPINE_WIDTH - 1e-6,
					`tier {ts.tier} A{n}/B{m} X-extents disjoint with the 1-stud spine between`
				)
			end
		end
	end
end)

test("stacked same-bay flights and landings: >= 9 studs vertical at every tread point", function()
	for _, ts in TIER_SPECS do
		local east, west, landings = stairsSplit(ts)
		for bayIndex, bay in { east, west } do
			for n = 1, #bay - 1 do
				local lower = bay[n]
				local upper = bay[n + 1]
				for _, t in TREAD_STEPS do
					local z = ts.mouthZ + t
					local clear = (centerlineY(upper, z) - upper.size.Y / 2)
						- (centerlineY(lower, z) + lower.size.Y / 2)
					expect.ok(
						clear >= STACK_CLEAR - 1e-6,
						`tier {ts.tier} bay {bayIndex} flights {n}->{n + 1}: {clear} studs at z {z} (need 9 = pitch - plank)`
					)
				end
			end
		end
		for n = 1, #landings - 1 do
			local clear = (landings[n + 1].offset.Y - landings[n + 1].size.Y / 2)
				- (landings[n].offset.Y + landings[n].size.Y / 2)
			expect.ok(
				clear >= STACK_CLEAR - 1e-6,
				`tier {ts.tier} landings {n}->{n + 1}: {clear} studs clear (need 9 = pitch - plank)`
			)
		end
	end
end)

test("headroom >= 8 over every tread and landing point against every overhead horizontal solid", function()
	-- Tread plane = the plank centerline / landing top (the §2.5 accounting:
	-- B5 tops out at the roof y with the bulkhead cap underside 8 above).
	-- Wall openings are pinned separately (doors are 6 x 7 by §2.3; bulkhead
	-- doorway test below) — walls never overhang a tread mid-flight.
	for _, ts in TIER_SPECS do
		local result = generated(ts)
		local east, west, landings = stairsSplit(ts)
		local overhead: { StairPart } = {}
		for _, list in { result.slabs, result.stairs } do
			for _, part in list do
				table.insert(overhead, part)
			end
		end
		local function zSpanOf(part: StairPart): (number, number)
			if part.orientation ~= nil and math.abs(part.orientation.X) > 0.01 then
				return runSpan(part)
			end
			return part.offset.Z - part.size.Z / 2, part.offset.Z + part.size.Z / 2
		end
		local function undersideAt(part: StairPart, z: number): number
			if part.orientation ~= nil and math.abs(part.orientation.X) > 0.01 then
				return centerlineY(part, z) - part.size.Y / 2
			end
			return part.offset.Y - part.size.Y / 2
		end
		local function checkPoint(px: number, walkY: number, pz: number, who: string)
			for _, part in overhead do
				local minX = part.offset.X - part.size.X / 2
				local maxX = part.offset.X + part.size.X / 2
				local minZ, maxZ = zSpanOf(part)
				if px > minX + 1e-3 and px < maxX - 1e-3 and pz > minZ + 1e-3 and pz < maxZ - 1e-3 then
					local underside = undersideAt(part, pz)
					if underside > walkY + 0.05 then
						expect.ok(
							underside - walkY >= HEADROOM_MIN - 1e-6,
							`tier {ts.tier} {who}: only {underside - walkY} studs of headroom at ({px}, {pz})`
						)
					end
				end
			end
		end
		for bayIndex, bay in { east, west } do
			for n, plank in bay do
				for _, t in TREAD_STEPS do
					local z = ts.mouthZ + t
					checkPoint(plank.offset.X, centerlineY(plank, z), z, `bay {bayIndex} flight {n} tread`)
				end
			end
		end
		local coreCenterX = (ts.coreMinX + ts.coreMaxX) / 2
		for n, landing in landings do
			local top = landing.offset.Y + landing.size.Y / 2
			for _, px in { westCenter(ts), coreCenterX, eastCenter(ts) } do
				local z = ts.mouthZ + RUN + 0.5
				while z < ts.mouthZ + RUN + LANDING_DEPTH do
					checkPoint(px, top, z, `landing {n}`)
					z += 1
				end
			end
		end
	end
end)

--------------------------------------------------------------------------------
-- Walk-path continuity (AC-R5.1, plan-side)
--------------------------------------------------------------------------------

test("walk chain F1 -> flights -> roof: ZERO vertical discontinuity at every junction", function()
	for _, ts in TIER_SPECS do
		local east, west, landings = stairsSplit(ts)
		local mouth = ts.mouthZ
		-- Floor 1 top of record: the ground slab is ONE plate of thickness ==
		-- FFL1 (plan D3), so the chain starts at y = ffl1 exactly.
		local walkY = ts.ffl1
		for n = 1, ts.floors do
			local a, b, landing = east[n], west[n], landings[n]
			expect.near(centerlineY(a, mouth), walkY, 1e-3, `tier {ts.tier} A{n} foot meets floor {n} top flush`)
			local landingTop = landing.offset.Y + landing.size.Y / 2
			expect.near(
				centerlineY(a, mouth + RUN),
				landingTop,
				1e-3,
				`tier {ts.tier} A{n} head flush with landing {n} top`
			)
			expect.near(
				centerlineY(b, mouth + RUN),
				landingTop,
				1e-3,
				`tier {ts.tier} B{n} foot meets landing {n} top flush`
			)
			walkY = centerlineY(b, mouth)
			expect.near(walkY, floorTop(ts, n) + PITCH, 1e-3, `tier {ts.tier} B{n} head flush with the next slab top`)
		end
		expect.near(walkY, roofTop(ts), 1e-3, `tier {ts.tier} chain tops out exactly at the roof slab top`)
	end
end)

--------------------------------------------------------------------------------
-- Cutout, keep-clears, bulkhead (§2.4, §2.3, §2.5)
--------------------------------------------------------------------------------

test("full-shaft cutout: exactly the 13 x 14 core rectangle (partial corner cuts banned)", function()
	for _, ts in TIER_SPECS do
		local cutout = generated(ts).cutout
		expect.near(cutout.minX, ts.coreMinX, 1e-3, `tier {ts.tier} cutout west edge on the core`)
		expect.near(cutout.maxX, ts.coreMaxX, 1e-3, `tier {ts.tier} cutout east edge on the core`)
		expect.near(cutout.minZ, ts.coreMinZ, 1e-3, `tier {ts.tier} cutout front edge on the mouth plane`)
		expect.near(cutout.maxZ, ts.coreMaxZ, 1e-3, `tier {ts.tier} cutout back edge on the core`)
		expect.near(cutout.maxX - cutout.minX, CORE_WIDTH, 1e-3, `tier {ts.tier} cutout 13 wide`)
		expect.near(cutout.maxZ - cutout.minZ, CORE_DEPTH, 1e-3, `tier {ts.tier} cutout 14 deep`)
	end
end)

local function hasRect(rects: { Rect }, minX: number, maxX: number, minZ: number, maxZ: number): boolean
	for _, rect in rects do
		if
			math.abs(rect.minX - minX) <= 1e-3
			and math.abs(rect.maxX - maxX) <= 1e-3
			and math.abs(rect.minZ - minZ) <= 1e-3
			and math.abs(rect.maxZ - maxZ) <= 1e-3
		then
			return true
		end
	end
	return false
end

test("keep-clears of record: 6 x 6 arrival pad (west bay), full-width run-bottom strip, core rect", function()
	for _, ts in TIER_SPECS do
		local keepClears = generated(ts).keepClears
		expect.eq(#keepClears, 3, `tier {ts.tier} exactly the three §2.3 keep-clears`)
		expect.ok(
			hasRect(keepClears, ts.coreMinX, ts.coreMinX + BAY_WIDTH, ts.mouthZ - KEEP_CLEAR_DEPTH, ts.mouthZ),
			`tier {ts.tier} 6 x 6 arrival pad in front of the west bay`
		)
		expect.ok(
			hasRect(keepClears, ts.coreMinX, ts.coreMaxX, ts.mouthZ - KEEP_CLEAR_DEPTH, ts.mouthZ),
			`tier {ts.tier} run-bottom strip 6 deep across the full mouth width`
		)
		expect.ok(
			hasRect(keepClears, ts.coreMinX, ts.coreMaxX, ts.coreMinZ, ts.coreMaxZ),
			`tier {ts.tier} core rectangle keep-clear`
		)
	end
end)

test("bulkhead: cap 8 above the roof over the full core; doorway over the WEST bay only; spine continues", function()
	for _, ts in TIER_SPECS do
		local result = generated(ts)
		local rt = roofTop(ts)
		-- Cap slab of record: y roofTop+8..+9 over the whole core rect, so
		-- the open well behind the east face is roofed, never rained into.
		local capFound = false
		for _, slab in result.slabs do
			local bottom = slab.offset.Y - slab.size.Y / 2
			local coversCore = slab.offset.X - slab.size.X / 2 <= ts.coreMinX + 1e-3
				and slab.offset.X + slab.size.X / 2 >= ts.coreMaxX - 1e-3
				and slab.offset.Z - slab.size.Z / 2 <= ts.coreMinZ + 1e-3
				and slab.offset.Z + slab.size.Z / 2 >= ts.coreMaxZ - 1e-3
			if math.abs(bottom - (rt + BULKHEAD_WALL_HEIGHT)) <= 0.01 and coversCore then
				capFound = true
				expect.near(
					slab.offset.Y + slab.size.Y / 2,
					rt + BULKHEAD_WALL_HEIGHT + 1,
					0.01,
					`tier {ts.tier} bulkhead cap is the 1-thick plate of record`
				)
			end
		end
		expect.ok(capFound, `tier {ts.tier} bulkhead cap covers the full core 8 above the roof`)

		-- Mouth-face walls at the bulkhead storey: solid over the east bay
		-- (the drop to the top landing stays unreachable), 6 x 7 doorway over
		-- the west bay where flight B tops out flush with the roof slab.
		local mouthWalls: { StairPart } = {}
		for _, wall in result.walls do
			local bottom = wall.offset.Y - wall.size.Y / 2
			if bottom >= rt - 0.01 and math.abs(wall.offset.Z - ts.mouthZ) <= 1 then
				table.insert(mouthWalls, wall)
			end
		end
		local function solidAt(x: number, y: number): boolean
			for _, wall in mouthWalls do
				if
					math.abs(x - wall.offset.X) < wall.size.X / 2 - 1e-3
					and math.abs(y - wall.offset.Y) < wall.size.Y / 2 - 1e-3
				then
					return true
				end
			end
			return false
		end
		for _, dx in { -2, 0, 2 } do
			for _, dy in { 1, 3.5, 6.5 } do
				expect.ok(
					solidAt(eastCenter(ts) + dx, rt + dy),
					`tier {ts.tier} bulkhead east-bay mouth face solid at dx {dx} dy {dy}`
				)
			end
		end
		for _, dx in { -2.5, 0, 2.5 } do
			for _, dy in { 0.5, 3.5, DOOR_HEIGHT - 0.5 } do
				expect.ok(
					not solidAt(westCenter(ts) + dx, rt + dy),
					`tier {ts.tier} 6 x 7 doorway open over the west bay at dx {dx} dy {dy}`
				)
			end
		end

		-- Spine wall extends through the bulkhead storey (§2.5).
		local spineFound = false
		for _, wall in result.walls do
			local minX = wall.offset.X - wall.size.X / 2
			local maxX = wall.offset.X + wall.size.X / 2
			if
				minX >= ts.coreMinX + BAY_WIDTH - 0.01
				and maxX <= ts.coreMinX + BAY_WIDTH + SPINE_WIDTH + 0.01
				and wall.offset.Y + wall.size.Y / 2 >= rt + 4
			then
				spineFound = true
			end
		end
		expect.ok(spineFound, `tier {ts.tier} spine wall continues through the bulkhead storey`)
	end
end)

--------------------------------------------------------------------------------
-- Color discipline (D8 / the boot-crash class)
--------------------------------------------------------------------------------

test("colors stay raw frozen RGB tables; Neon dressing at identity brightness (max channel >= 217)", function()
	for _, ts in TIER_SPECS do
		local result = generated(ts)
		expect.ok(#result.neon > 0, `tier {ts.tier} emits Neon dressing (handrail caps at minimum)`)
		local categories: { [string]: { StairPart } } = {
			stairs = result.stairs,
			walls = result.walls,
			slabs = result.slabs,
			neon = result.neon,
		}
		for listName, list in categories do
			for index, part in list do
				local color = part.color
				if color ~= nil then
					expect.ok(
						type(color) == "table",
						`tier {ts.tier} {listName}[{index}] color is a raw RGB table (Color3 is builder-side ONLY)`
					)
					for _, channel in { "R", "G", "B" } do
						local value = (color :: any)[channel]
						expect.ok(
							type(value) == "number" and value >= 0 and value <= 255,
							`tier {ts.tier} {listName}[{index}] channel {channel} is a 0-255 number`
						)
					end
				end
			end
		end
		for index, part in result.neon do
			local color = part.color
			if color ~= nil then
				expect.ok(
					math.max(color.R, color.G, color.B) >= 217,
					`tier {ts.tier} neon[{index}] at identity V (D8: max channel >= 217)`
				)
			end
		end
	end
end)

return { name = "house stairs (HousePlanStairs core generator)", tests = tests }
