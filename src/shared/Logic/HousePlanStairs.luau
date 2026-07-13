--!strict
-- CRYPTLINGS: NIGHT SHIFT — R5 U-switchback stair-core generator (WP1.1;
-- plan of record LOBBY_BUILD_PLAN_R5.md D1/D2/D10, spec of record
-- LOBBY_SOP_ADDENDUM_4.md §2). One dedicated stair core per house,
-- back-right corner, internal footprint 13 wide x 14 deep, identical at
-- every storey and continued one extra storey to the roof bulkhead. The
-- geometry makes ramp-blocks-ramp impossible BY CONSTRUCTION: arrival and
-- departure flights occupy different bays of the same shaft, and stacked
-- same-bay flights are separated by a full pitch with thin planks between.
--
-- Pure Luau: no Roblox globals (lune-safe), zero requires, no Instances, no
-- yields; every returned table is frozen. HousePlan composes Generate() per
-- tier (WP2.1); ShelfRoomBuilder / HousePreviewController apply orientation
-- via CFrame.new(offset) * CFrame.Angles(rad(X), rad(Y), rad(Z)) and convert
-- color {R,G,B} via Color3.fromRGB at APPLY time ONLY (assigning a raw table
-- to a Color3 property is the recurring boot-crash class — never here).
--
-- ===========================================================================
-- BINDING TABLES (transcribed from Addendum 4 §2 — NOT advisory)
-- ===========================================================================
--
-- §2.3 EXACT NUMBERS
--   Storey pitch                10 (9 wall + 1 slab)
--   Flights per transition      2 (A up to landing, B landing to next floor)
--   Rise per flight             5 (half pitch)
--   Run per flight              8
--   Slope                       32.005 deg = atan(5/8) — <= 35 comfort cap;
--                               the old 48.4-deg full-pitch wedge abolished
--   Flight width (clear)        6 (AgentRadius 2 -> 4 min; +1/side margin)
--   Plank thickness             1 (vertical)
--   Half-landing                13w x 6d x 1, top at y0+5 (depth >= width)
--   Spine wall between bays     1 thick x storey height, z mouth..mouth+8,
--                               Neon handrail cap 0.3
--   Core enclosure wall         1 thick x full height per storey on the
--   (gallery side)              core's open side — closes the shaft; no
--                               exposed drop edges anywhere in the core
--   Headroom over every tread   9.0 vertical (pitch 10 - plank 1); >= 8 floor
--   Headroom over landings      9.0 (next landing underside is y0+14)
--   Arrival pad                 6 x 6 minimum, keep-clear enforced
--   Run-bottom keep-clear       6 studs of clear floor across the mouth width
--   Door openings               7w x 7h (front), 6w x 7h (bulkhead/terrace)
--   Guards                      >= 3 high x 1 thick at ANY exposed slab edge
--                               (the engine auto-steps <= 2.5)
--
-- BAY ASSIGNMENT (same every storey, every tier): facing the core from the
-- gallery (looking +Z), EAST bay = up-flight A (departure), spine in the
-- middle, WEST bay = down-edge of flight B (arrival). A player topping
-- flight B steps off heading -Z into the gallery; the next up-flight starts
-- 7 studs to their east in the other bay. Arrival and departure can never
-- overlap.
--
-- §2.4 SLAB CUTOUT FORMULA + FULL-SHAFT RULE: for a run of rise R over
-- length L passing under a slab (pitch P, slab thickness t, headroom C) the
-- slab must be open from x0 = L*(P - t - C)/R before the run top; opening
-- length = L*(R - P + t + C)/R. Worked for R5 (P=10, t=1, C=8, R=5, L=8):
-- required opening = 8*(5-10+1+8)/5 = 6.4 studs over the end of flight B.
-- RULE: every slab above floor 1 — INCLUDING THE ROOF SLAB — opens the
-- ENTIRE core rectangle (13 x 14) as one cutout (cheap L-shaped slab = 2
-- rects, cut by the callers from `cutout` below). Partial corner cuts are
-- banned. The cutout never creates a fall hazard because all four core
-- boundaries are either house walls, the enclosure wall, or filled by
-- flights at the mouth.
--
-- §2.5 WORKED EXAMPLE — TIER 3 MANSION, ALL FIVE TRANSITIONS (binding).
-- Lot-local; core x +6.5..+19.5, z +10.5..+24.5; mouth plane z +10.5; east
-- bay x +13.5..+19.5, spine +12.5..+13.5, west bay +6.5..+12.5. Heights
-- relative to FFL1 (= pad +3); floor tops F1 0, F2 10, F3 20, F4 30, F5 40,
-- roof slab top 50:
--   F1->F2   A: z +10.5->+18.5, y 0->5 | landing 13x6 @ z +18.5..+24.5, y 5
--            B: z +18.5->+10.5, y 5->10, top flush with the F2 slab.
--            Pad = x +6.5..+12.5, z +4.5..+10.5 (6x6, podium-free).
--            Headroom: above A1 is the A2 plank, 10 - 1 = 9.0; above
--            landing1 is landing2's underside (y 14): 9.0.
--   F2->F3   same XZ, y 10->15 | y 15 | y 15->20 — identical, 9.0 everywhere
--   F3->F4   same XZ, y 20->25 | y 25 | y 25->30 — 9.0
--   F4->F5   same XZ, y 30->35 | y 35 | y 35->40 — 9.0 (the floor-5 setback
--            is at the FRONT of the house; the core is untouched)
--   F5->Roof same XZ, y 40->45 | y 45 | y 45->50, top flush with the roof
--            slab at the mouth. Player tops out AT the bulkhead doorway
--            (6w x 7h over the west bay at the mouth plane) and steps -Z
--            onto the terrace; pad = terrace slab x +6.5..+12.5,
--            z +4.5..+10.5. Above A5/landing5/B5 is the bulkhead cap.
--
-- ROOF BULKHEAD (T3 numbers; T1/T2 identical relative to their cores):
-- 3 walls + flat cap enclosing the core footprint above the roof — walls 8
-- high (y 50..58), cap slab y 58..59; the front (-Z) face at the mouth plane
-- carries the 6x7 doorway over the WEST bay only — the east-bay face is
-- solid wall, so the open well behind it (drop to landing5, -5) is
-- unreachable. The spine wall extends through the bulkhead storey.
--
-- NO-OVERLAP PROOF (the binding check):
--   * Flight An vs flight Bn: disjoint in X (east bay vs west bay; spine
--     wall between).
--   * Flight An vs An+1 (identical XZ): vertical separation = pitch 10;
--     planks 1 thick -> 9.0 studs clear above every tread of An. Same for
--     Bn vs Bn+1 and landing(n) vs landing(n+1).
--   * Arrival point of Bn (west bay, mouth, floor n+1) vs departure
--     envelope of An+1 (east bay, z mouth..mouth+8): disjoint in X by 7
--     studs (the old bug, dead).
--   * Every slab from F2 through the roof opens the full 13x14 core -> no
--     partial-slab head clip is geometrically possible; §2.4 requires only
--     6.4 of the 8-stud run open.
--
-- TIER CORE MAPPING (lot-local; mouth plane = core min z at every tier):
--   T1: core x +2.5..+15.5, z +0.5..+14.5; mouth z +0.5; flights z
--       +0.5..+8.5; landing z +8.5..+14.5; bays W +2.5..+8.5 / E +9.5..+15.5
--   T2: core x +4.5..+17.5, z +6..+20; mouth z +6; flights z +6..+14;
--       landing z +14..+20; bays W +4.5..+10.5 / E +11.5..+17.5
--   T3: core x +6.5..+19.5, z +10.5..+24.5; mouth z +10.5; flights z
--       +10.5..+18.5; landing z +18.5..+24.5; bays W +6.5..+12.5 /
--       E +13.5..+19.5
--   T1 runs the template once (F1 -> roof) + bulkhead, T2 twice + bulkhead,
--   T3 five times + bulkhead. Same plank/landing/headroom numbers at all
--   tiers.
-- ===========================================================================
--
-- EMISSION NOTES (this module's reading of the contract, documented so the
-- Wave-2 composers inherit the reasoning, not just the numbers):
--   * Enclosure wall placement: the core's back (+Z) and east (+X) faces are
--     house walls at all three tiers (the core rects are flush with the
--     interior wall faces), so the §2.3 gallery-side enclosure goes on the
--     WEST plane — flight B climbs that face 5..10 studs above the gallery
--     floor and would otherwise expose a drop edge along its whole run plus
--     the landing's west edge. It sits just OUTSIDE the core rect
--     (x coreMinX-1..coreMinX) so the west bay keeps its full 6-stud clear
--     width and the wall stands on solid slab (the cutout is exactly the
--     core rect). Height 9 per storey: the solid slab band above (slabs are
--     only cut over the rect) fills y +9..+10, so the guard line is
--     continuous floor to floor.
--   * NO header/door is emitted on the mouth plane for regular storeys: §2.3
--     specifies doors only at the front entry and bulkhead/terrace, and any
--     mouth header at door height would cut headroom over flight A's
--     threshold treads below the binding >= 8 floor (a 7-high header leaves
--     ~6.4 over the first tread). The mouth stays open the full storey
--     height; the "filled by flights at the mouth" clause of §2.4 is what
--     closes it.
--   * Plank center convention (D1/WP1.1, binding): center at the run
--     midpoint, mid-height baseY + rise/2, length sqrt(run^2 + rise^2).
--     Half-thickness effects make the inclined top surface's end edges sit
--     +cos(slope)/2 (~0.42) proud of the exact floor/landing planes with a
--     ~0.27 z overhang — far inside the engine's 2.5 auto-step, walk-tested
--     in R5 smoke, and identical at every transition of every tier.
--   * Bulkhead walls ring the core rect just OUTSIDE it on all four planes:
--     they stand on the solid roof slab (never hover over the shaft) and
--     leave the §2.5 headroom over A/landing/B of the top transition to the
--     cap alone. The cap covers the wall ring (rect + 1 each side). The
--     doorway threshold (z coreMinZ-1..coreMinZ, west bay) is solid roof
--     slab at exactly roofTop — flush walk-off from flight B's top.
--
--   StairCore.Generate(spec) -> StairCoreResult
--     spec: {
--       coreMinX/coreMaxX/coreMinZ/coreMaxZ: the 13x14 internal core rect,
--       mouthZ: gallery-side opening plane (== coreMinZ at every tier),
--       ffl1: floor-1 top above the pad (lot-local y of floor 1),
--       floors: storey count (1/2/5); transitions = floors (top -> roof),
--       pitch: storey pitch — must equal the binding 10,
--       accentColors: per-transition frozen {R,G,B} Neon handrail accents
--                     (clamped to the last entry when shorter than floors),
--     }
--     returns (all frozen): {
--       stairs: planks + half-landings (CanCollide; ONLY planks carry
--               orientation, ONLY about X — D2 orientation discipline),
--       walls: spine + enclosure walls per storey + bulkhead box,
--       slabs: bulkhead cap,
--       neon: spine handrail caps (0.3, per-floor accent color),
--       cutout: the full 13x14 core rect — callers L-cut EVERY slab above
--               floor 1 (roof included) with it,
--       keepClears: arrival pad (west bay x 6 deep), run-bottom strip
--                   (mouth width x 6), core rect,
--     }

export type Dim3 = { X: number, Y: number, Z: number }
export type RGB = { R: number, G: number, B: number }

-- D2 ShellPart contract (verbatim shape; HousePlan re-exports its own):
export type ShellPart = {
	size: Dim3,
	offset: Dim3, -- part center, lot-local frame
	orientation: Dim3?, -- degrees; CFrame.new(offset) * CFrame.Angles(rad(X), rad(Y), rad(Z)); nil = axis-aligned
	color: RGB?, -- frozen {R,G,B} 0-255, Color3.fromRGB at APPLY time only; nil = category default
}

export type Rect = { minX: number, maxX: number, minZ: number, maxZ: number }
export type KeepClear = { minX: number, maxX: number, minZ: number, maxZ: number, kind: string }

export type StairSpec = {
	coreMinX: number,
	coreMaxX: number,
	coreMinZ: number,
	coreMaxZ: number,
	mouthZ: number,
	ffl1: number,
	floors: number,
	pitch: number,
	accentColors: { RGB },
}

export type StairCoreResult = {
	stairs: { ShellPart },
	walls: { ShellPart },
	slabs: { ShellPart },
	neon: { ShellPart },
	cutout: Rect,
	keepClears: { KeepClear },
}

--------------------------------------------------------------------------------
-- §2.3 constants of record (the binding tables above are the source of truth)
--------------------------------------------------------------------------------

local STOREY_PITCH = 10 -- 9 wall + 1 slab
local SLAB_THICKNESS = 1
local STOREY_WALL_HEIGHT = STOREY_PITCH - SLAB_THICKNESS -- 9
local FLIGHTS_PER_TRANSITION = 2
local FLIGHT_RISE = 5 -- per flight; half pitch
local FLIGHT_RUN = 8
local FLIGHT_WIDTH = 6 -- clear bay width
local PLANK_THICKNESS = 1
local LANDING_DEPTH = 6 -- >= FLIGHT_WIDTH (scaled 36" rule)
local LANDING_THICKNESS = 1
local SPINE_THICKNESS = 1
local HANDRAIL_CAP_THICKNESS = 0.3
local ENCLOSURE_THICKNESS = 1
local ARRIVAL_PAD_STUDS = 6 -- 6x6 minimum, west bay, outside the mouth
local RUN_BOTTOM_CLEAR_STUDS = 6 -- across the full mouth width
local BULKHEAD_WALL_HEIGHT = 8 -- roofTop..+8, cap +8..+9
local BULKHEAD_CAP_THICKNESS = 1
local BULKHEAD_DOOR_WIDTH = 6 -- == west bay width
local BULKHEAD_DOOR_HEIGHT = 7

local CORE_WIDTH = 2 * FLIGHT_WIDTH + SPINE_THICKNESS -- 13
local CORE_DEPTH = FLIGHT_RUN + LANDING_DEPTH -- 14

-- NEVER hand-typed (plan D2 orientation discipline): the one slope of record.
local SLOPE_DEGREES = math.deg(math.atan(FLIGHT_RISE / FLIGHT_RUN))
local PLANK_LENGTH = math.sqrt(FLIGHT_RUN * FLIGHT_RUN + FLIGHT_RISE * FLIGHT_RISE)
local HEADROOM_STUDS = STOREY_PITCH - PLANK_THICKNESS -- 9.0

-- Require-time invariants (WP1.1 item 6): a stair core that breaks the §2.3
-- comfort/clearance contract must fail at require time, not at walk time.
assert(SLOPE_DEGREES <= 35, "HousePlanStairs: flight slope breaches the 35-degree comfort cap")
assert(HEADROOM_STUDS >= 8, "HousePlanStairs: headroom (pitch - plank) fell below the 8-stud floor")
assert(LANDING_DEPTH >= FLIGHT_WIDTH, "HousePlanStairs: half-landing shallower than the flight width")
assert(FLIGHT_WIDTH == 6, "HousePlanStairs: bay width drifted from the 6-stud spec of record")
assert(SPINE_THICKNESS == 1, "HousePlanStairs: spine wall drifted from the 1-stud spec of record")
assert(FLIGHTS_PER_TRANSITION * FLIGHT_RISE == STOREY_PITCH, "HousePlanStairs: flights no longer sum to the pitch")
assert(CORE_WIDTH == 13 and CORE_DEPTH == 14, "HousePlanStairs: core rect drifted from 13 x 14")

--------------------------------------------------------------------------------
-- Internal helpers
--------------------------------------------------------------------------------

local function dim3(x: number, y: number, z: number): Dim3
	return table.freeze({ X = x, Y = y, Z = z })
end

local function axisPart(sizeX: number, sizeY: number, sizeZ: number, x: number, y: number, z: number): ShellPart
	return table.freeze({ size = dim3(sizeX, sizeY, sizeZ), offset = dim3(x, y, z) })
end

local function neonPart(
	sizeX: number,
	sizeY: number,
	sizeZ: number,
	x: number,
	y: number,
	z: number,
	color: RGB
): ShellPart
	return table.freeze({ size = dim3(sizeX, sizeY, sizeZ), offset = dim3(x, y, z), color = color })
end

-- THE one owner of stair rotation (plan D1/WP1.1 item 2; nothing else in the
-- codebase may emit an orientation). A flight is one Part,
-- sqrt(run^2 + rise^2) long x `width` wide x 1 thick, centered at the run's
-- XZ midpoint at mid-height baseY + rise/2, rotated about its width (X) axis
-- only. Sign derivation, not convention: builders apply
-- CFrame.new(offset) * CFrame.Angles(rad(X), 0, 0), and R_x maps the part's
-- local +Z axis to world (0, -sin X, cos X) — the +Z end RISES for negative
-- X. So ascending toward +Z carries orientation.X = -slope; ascending toward
-- -Z carries +slope. `baseY` is the surface height at the flight's LOW end
-- (the mouthZ end when ascending toward +Z, the mouthZ+run end otherwise).
local function plank(
	width: number,
	rise: number,
	run: number,
	centerX: number,
	baseY: number,
	mouthZ: number,
	ascendingTowardPlusZ: boolean
): ShellPart
	local length = math.sqrt(run * run + rise * rise)
	local slope = math.deg(math.atan(rise / run))
	local orientationX = if ascendingTowardPlusZ then -slope else slope
	return table.freeze({
		size = dim3(width, PLANK_THICKNESS, length),
		offset = dim3(centerX, baseY + rise / 2, mouthZ + run / 2),
		orientation = dim3(orientationX, 0, 0),
	})
end

local function nearly(a: number, b: number): boolean
	return math.abs(a - b) < 1e-6
end

local function assertRGB(color: RGB, label: string)
	for _, channel in { color.R, color.G, color.B } do
		assert(
			type(channel) == "number" and channel >= 0 and channel <= 255,
			`HousePlanStairs: {label} channel out of the 0..255 fromRGB range`
		)
	end
end

local function keepClear(minX: number, maxX: number, minZ: number, maxZ: number, kind: string): KeepClear
	return table.freeze({ minX = minX, maxX = maxX, minZ = minZ, maxZ = maxZ, kind = kind })
end

--------------------------------------------------------------------------------
-- Public surface
--------------------------------------------------------------------------------

local StairCore = {}

-- Constants of record, exported read-only so the suite/composers never
-- re-literal them (HousePlan re-exports what its consumers need).
StairCore.STOREY_PITCH_STUDS = STOREY_PITCH
StairCore.FLIGHT_RISE_STUDS = FLIGHT_RISE
StairCore.FLIGHT_RUN_STUDS = FLIGHT_RUN
StairCore.FLIGHT_WIDTH_STUDS = FLIGHT_WIDTH
StairCore.PLANK_THICKNESS_STUDS = PLANK_THICKNESS
StairCore.PLANK_LENGTH_STUDS = PLANK_LENGTH
StairCore.SLOPE_DEGREES = SLOPE_DEGREES
StairCore.HEADROOM_STUDS = HEADROOM_STUDS
StairCore.CORE_WIDTH_STUDS = CORE_WIDTH
StairCore.CORE_DEPTH_STUDS = CORE_DEPTH
StairCore.LANDING_DEPTH_STUDS = LANDING_DEPTH
StairCore.ARRIVAL_PAD_STUDS = ARRIVAL_PAD_STUDS
StairCore.RUN_BOTTOM_CLEAR_STUDS = RUN_BOTTOM_CLEAR_STUDS
StairCore.BULKHEAD_WALL_HEIGHT_STUDS = BULKHEAD_WALL_HEIGHT
StairCore.BULKHEAD_DOOR_WIDTH_STUDS = BULKHEAD_DOOR_WIDTH
StairCore.BULKHEAD_DOOR_HEIGHT_STUDS = BULKHEAD_DOOR_HEIGHT

-- Generate the full stair core for one house: `floors` transitions (the top
-- one lands on the roof) + the roof bulkhead. Pure and deterministic; all
-- coordinates lot-local. See the module header for every binding number.
function StairCore.Generate(spec: StairSpec): StairCoreResult
	local coreMinX = spec.coreMinX
	local coreMaxX = spec.coreMaxX
	local coreMinZ = spec.coreMinZ
	local coreMaxZ = spec.coreMaxZ
	local mouthZ = spec.mouthZ
	local ffl1 = spec.ffl1
	local floors = spec.floors
	local accentColors = spec.accentColors

	assert(nearly(coreMaxX - coreMinX, CORE_WIDTH), "HousePlanStairs: core rect must be exactly 13 wide")
	assert(nearly(coreMaxZ - coreMinZ, CORE_DEPTH), "HousePlanStairs: core rect must be exactly 14 deep")
	assert(nearly(mouthZ, coreMinZ), "HousePlanStairs: the mouth plane is the core's -Z edge at every tier")
	assert(
		spec.pitch == FLIGHTS_PER_TRANSITION * FLIGHT_RISE,
		"HousePlanStairs: caller pitch drifted from the 5 + 5 half-pitch flights of record"
	)
	assert(type(floors) == "number" and floors % 1 == 0 and floors >= 1, "HousePlanStairs: floors must be >= 1")
	assert(ffl1 >= 0, "HousePlanStairs: ffl1 must sit on or above the pad")
	assert(#accentColors >= 1, "HousePlanStairs: at least one handrail accent color is required")
	for index, color in accentColors do
		assertRGB(color, `accentColors[{index}]`)
	end

	-- Bay planes (BAY ASSIGNMENT table): west = arrival, spine, east = departure.
	local westCenterX = coreMinX + FLIGHT_WIDTH / 2 -- +3
	local spineCenterX = coreMinX + FLIGHT_WIDTH + SPINE_THICKNESS / 2 -- +6.5 (== core center)
	local eastCenterX = coreMinX + FLIGHT_WIDTH + SPINE_THICKNESS + FLIGHT_WIDTH / 2 -- +10
	local coreCenterX = (coreMinX + coreMaxX) / 2
	local coreCenterZ = (coreMinZ + coreMaxZ) / 2
	local roofTop = ffl1 + floors * STOREY_PITCH -- roof slab TOP (D6: 11 / 23 / 53)

	local stairs: { ShellPart } = {}
	local walls: { ShellPart } = {}
	local slabs: { ShellPart } = {}
	local neon: { ShellPart } = {}

	for transition = 1, floors do
		local yBase = ffl1 + (transition - 1) * STOREY_PITCH -- floor `transition` top
		local accent = accentColors[math.min(transition, #accentColors)]

		-- Flight A (east bay, departure): z mouth..mouth+8, y yBase -> +5.
		table.insert(stairs, plank(FLIGHT_WIDTH, FLIGHT_RISE, FLIGHT_RUN, eastCenterX, yBase, mouthZ, true))

		-- Half-landing 13 x 6 x 1, top at yBase + 5, z mouth+8..mouth+14.
		table.insert(
			stairs,
			axisPart(
				CORE_WIDTH,
				LANDING_THICKNESS,
				LANDING_DEPTH,
				coreCenterX,
				yBase + FLIGHT_RISE - LANDING_THICKNESS / 2,
				mouthZ + FLIGHT_RUN + LANDING_DEPTH / 2
			)
		)

		-- Flight B (west bay, arrival): z mouth+8..mouth, y +5 -> +10, top
		-- flush with the next slab at the mouth.
		table.insert(
			stairs,
			plank(FLIGHT_WIDTH, FLIGHT_RISE, FLIGHT_RUN, westCenterX, yBase + FLIGHT_RISE, mouthZ, false)
		)

		-- Spine wall between the bays: 1 thick, z mouth..mouth+8, wall-height
		-- per storey (the slab band above the core rect is open shaft; the
		-- 0.3 Neon cap below stays clear of the next storey's spine).
		table.insert(
			walls,
			axisPart(
				SPINE_THICKNESS,
				STOREY_WALL_HEIGHT,
				FLIGHT_RUN,
				spineCenterX,
				yBase + STOREY_WALL_HEIGHT / 2,
				mouthZ + FLIGHT_RUN / 2
			)
		)

		-- Gallery-side enclosure wall (§2.3): the core's open WEST face, just
		-- outside the rect, full core depth — guards flight B's climb and the
		-- landing's west edge. The solid slab band above (slabs are only cut
		-- over the rect) continues the guard line through y +9..+10.
		table.insert(
			walls,
			axisPart(
				ENCLOSURE_THICKNESS,
				STOREY_WALL_HEIGHT,
				CORE_DEPTH,
				coreMinX - ENCLOSURE_THICKNESS / 2,
				yBase + STOREY_WALL_HEIGHT / 2,
				coreCenterZ
			)
		)

		-- Neon handrail cap on the spine, per-floor accent (§3 wayfinding).
		table.insert(
			neon,
			neonPart(
				SPINE_THICKNESS,
				HANDRAIL_CAP_THICKNESS,
				FLIGHT_RUN,
				spineCenterX,
				yBase + STOREY_WALL_HEIGHT + HANDRAIL_CAP_THICKNESS / 2,
				mouthZ + FLIGHT_RUN / 2,
				accent
			)
		)
	end

	-- Roof bulkhead (ALL tiers — every tier gets the roof). Walls ring the
	-- core rect just outside it (standing on the solid roof slab, §2.5: only
	-- the cap is above the top transition's flights/landing); 6x7 doorway on
	-- the -Z face over the WEST bay only, east-bay face solid so the open
	-- well behind it is unreachable.
	local bulkheadWallY = roofTop + BULKHEAD_WALL_HEIGHT / 2
	-- Back (+Z) wall: full outer width, covers both rear corners.
	table.insert(walls, axisPart(CORE_WIDTH + 2, BULKHEAD_WALL_HEIGHT, 1, coreCenterX, bulkheadWallY, coreMaxZ + 0.5))
	-- East / west side walls: z coreMinZ-1..coreMaxZ (cover the front corners;
	-- the west wall stacks directly on the storey enclosure line below).
	table.insert(
		walls,
		axisPart(1, BULKHEAD_WALL_HEIGHT, CORE_DEPTH + 1, coreMaxX + 0.5, bulkheadWallY, coreCenterZ - 0.5)
	)
	table.insert(
		walls,
		axisPart(1, BULKHEAD_WALL_HEIGHT, CORE_DEPTH + 1, coreMinX - 0.5, bulkheadWallY, coreCenterZ - 0.5)
	)
	-- Front (-Z) face on the mouth plane: solid over spine + east bay ...
	table.insert(
		walls,
		axisPart(
			FLIGHT_WIDTH + SPINE_THICKNESS,
			BULKHEAD_WALL_HEIGHT,
			1,
			coreMinX + FLIGHT_WIDTH + (FLIGHT_WIDTH + SPINE_THICKNESS) / 2,
			bulkheadWallY,
			coreMinZ - 0.5
		)
	)
	-- ... and the 6x7 doorway header over the west bay (threshold below it is
	-- solid roof slab at exactly roofTop — flush walk-off from flight B).
	table.insert(
		walls,
		axisPart(
			BULKHEAD_DOOR_WIDTH,
			BULKHEAD_WALL_HEIGHT - BULKHEAD_DOOR_HEIGHT,
			1,
			coreMinX + BULKHEAD_DOOR_WIDTH / 2,
			roofTop + BULKHEAD_DOOR_HEIGHT + (BULKHEAD_WALL_HEIGHT - BULKHEAD_DOOR_HEIGHT) / 2,
			coreMinZ - 0.5
		)
	)
	-- Spine extends through the bulkhead storey (blocks the sidestep from the
	-- top of flight B into the east-bay well); top meets the cap underside.
	table.insert(
		walls,
		axisPart(
			SPINE_THICKNESS,
			BULKHEAD_WALL_HEIGHT,
			FLIGHT_RUN,
			spineCenterX,
			bulkheadWallY,
			mouthZ + FLIGHT_RUN / 2
		)
	)
	-- Flat cap over the core rect + its wall ring; top at roofTop + 9
	-- (D6 bulkhead cap tops: 20 / 32 / 62 above the pad).
	table.insert(
		slabs,
		axisPart(
			CORE_WIDTH + 2,
			BULKHEAD_CAP_THICKNESS,
			CORE_DEPTH + 2,
			coreCenterX,
			roofTop + BULKHEAD_WALL_HEIGHT + BULKHEAD_CAP_THICKNESS / 2,
			coreCenterZ
		)
	)

	return table.freeze({
		stairs = table.freeze(stairs),
		walls = table.freeze(walls),
		slabs = table.freeze(slabs),
		neon = table.freeze(neon),
		-- Callers L-cut EVERY slab above floor 1 — roof included — with this
		-- full-shaft rect (§2.4: partial corner cuts are banned).
		cutout = table.freeze({ minX = coreMinX, maxX = coreMaxX, minZ = coreMinZ, maxZ = coreMaxZ }),
		keepClears = table.freeze({
			-- Arrival pad: west bay width x 6 deep, outside the mouth.
			keepClear(coreMinX, coreMinX + FLIGHT_WIDTH, mouthZ - ARRIVAL_PAD_STUDS, mouthZ, "arrival_pad"),
			-- Run-bottom strip: the full mouth width x 6 of clear floor.
			keepClear(coreMinX, coreMaxX, mouthZ - RUN_BOTTOM_CLEAR_STUDS, mouthZ, "run_bottom"),
			-- The core rectangle itself.
			keepClear(coreMinX, coreMaxX, coreMinZ, coreMaxZ, "core"),
		}),
	})
end

return table.freeze(StairCore)
