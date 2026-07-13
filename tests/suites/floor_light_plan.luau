--!strict
-- Floor lighting plan suite (R6 Fix #1). Pins FloorLightPlan — the pure module
-- FloorGenService consumes to decide, per generic room, overhead-vs-night-light,
-- color and flicker. No Roblox APIs (Lune-safe).
--
-- The headline guarantee: >=50% of generic rooms are deterministically
-- overhead-lit on EVERY seed at EVERY density scale (kills the 1/N darkness bug),
-- and NO generic room is ever pitch black (every room is overhead OR night-lit).

local FloorLightPlan = require("../../src/shared/Logic/FloorLightPlan")
local expect = require("../expect")

local tests = {}
local function test(name: string, fn: () -> ())
	table.insert(tests, { name = name, fn = fn })
end

local ROOM_COUNT = 34 -- generic rooms on a 6x6 grid (36 cells - dock - vault)
local SCALES = { 1, 0.5, 0.2, 0.1 }

local function round(x: number): number
	return math.floor(x + 0.5)
end

-- Build a deterministic roll vector (mirrors what FloorGenService's seeded stream
-- feeds in: each generic room has a light roll and a flicker roll in [0,1)).
local function makeRolls(seed: number, count: number): { { light: number, flicker: number } }
	math.randomseed(seed)
	local rolls = {}
	for i = 1, count do
		rolls[i] = { light = math.random(), flicker = math.random() }
	end
	return rolls
end

local ROLL_SEEDS = { 0xA11CE, 0xB0B, 0xC0FFEE, 0xD15EA5E, 0xFEED }

--------------------------------------------------------------------------------

test(">=50% overhead-lit floor holds at every density scale and seed", function()
	local floor = math.ceil(ROOM_COUNT * 0.50)
	expect.eq(floor, 17, "ceil(34*0.5) == 17")
	for _, seed in ROLL_SEEDS do
		local rolls = makeRolls(seed, ROOM_COUNT)
		for _, scale in SCALES do
			local plan = FloorLightPlan.plan(seed, ROOM_COUNT, scale, rolls)
			expect.ok(
				plan.litCount >= floor,
				`seed {seed} scale {scale}: litCount {plan.litCount} >= 17`
			)
		end
	end
end)

test("5-session case (scale 0.2) holds AT the 17 floor, not collapse", function()
	for _, seed in ROLL_SEEDS do
		local rolls = makeRolls(seed, ROOM_COUNT)
		local plan = FloorLightPlan.plan(seed, ROOM_COUNT, 0.2, rolls)
		expect.eq(plan.litCount, 17, `seed {seed} scale 0.2 litCount == floor 17`)
	end
end)

test("full-density (scale 1) lights round(34*0.72) == 24", function()
	for _, seed in ROLL_SEEDS do
		local rolls = makeRolls(seed, ROOM_COUNT)
		local plan = FloorLightPlan.plan(seed, ROOM_COUNT, 1, rolls)
		expect.eq(plan.litCount, 24, `seed {seed} scale 1 litCount == 24`)
	end
end)

test("completeness: #rooms == roomCount and lit count matches litCount", function()
	for _, seed in ROLL_SEEDS do
		local rolls = makeRolls(seed, ROOM_COUNT)
		for _, scale in SCALES do
			local plan = FloorLightPlan.plan(seed, ROOM_COUNT, scale, rolls)
			expect.eq(#plan.rooms, ROOM_COUNT, "room array length")
			local litObserved = 0
			for _, room in plan.rooms do
				if room.lit then
					litObserved += 1
				end
			end
			expect.eq(litObserved, plan.litCount, `seed {seed} scale {scale} lit==litCount`)
		end
	end
end)

test("no pitch-black room: every room is exactly overhead OR night-lit", function()
	for _, seed in ROLL_SEEDS do
		local rolls = makeRolls(seed, ROOM_COUNT)
		for _, scale in SCALES do
			local plan = FloorLightPlan.plan(seed, ROOM_COUNT, scale, rolls)
			for index, room in plan.rooms do
				if room.lit then
					expect.ok(room.overheadColor ~= nil, `room {index} lit has overheadColor`)
					expect.ok(room.nightColor == nil, `room {index} lit has no nightColor`)
				else
					expect.ok(room.nightColor ~= nil, `room {index} unlit has nightColor`)
					expect.ok(room.overheadColor == nil, `room {index} unlit has no overheadColor`)
				end
			end
		end
	end
end)

test("night colors are ONLY orange or purple", function()
	for _, seed in ROLL_SEEDS do
		local rolls = makeRolls(seed, ROOM_COUNT)
		for _, scale in SCALES do
			local plan = FloorLightPlan.plan(seed, ROOM_COUNT, scale, rolls)
			for index, room in plan.rooms do
				if not room.lit then
					expect.ok(
						room.nightColor == "orange" or room.nightColor == "purple",
						`room {index} nightColor {tostring(room.nightColor)} is orange|purple`
					)
				end
			end
		end
	end
end)

test("overhead colors are ONLY warm, orange or cyan", function()
	for _, seed in ROLL_SEEDS do
		local rolls = makeRolls(seed, ROOM_COUNT)
		local plan = FloorLightPlan.plan(seed, ROOM_COUNT, 1, rolls)
		for index, room in plan.rooms do
			if room.lit then
				expect.ok(
					room.overheadColor == "warm"
						or room.overheadColor == "orange"
						or room.overheadColor == "cyan",
					`room {index} overheadColor {tostring(room.overheadColor)} valid`
				)
			end
		end
	end
end)

test("overhead color counts equal round(litCount*0.20) orange / round(litCount*0.10) cyan", function()
	for _, seed in ROLL_SEEDS do
		local rolls = makeRolls(seed, ROOM_COUNT)
		for _, scale in SCALES do
			local plan = FloorLightPlan.plan(seed, ROOM_COUNT, scale, rolls)
			local orange, cyan = 0, 0
			for _, room in plan.rooms do
				if room.overheadColor == "orange" then
					orange += 1
				elseif room.overheadColor == "cyan" then
					cyan += 1
				end
			end
			expect.eq(orange, round(plan.litCount * 0.20), `seed {seed} scale {scale} orange count`)
			expect.eq(cyan, round(plan.litCount * 0.10), `seed {seed} scale {scale} cyan count`)
		end
	end
end)

test("determinism: identical args produce deep-equal plans", function()
	for _, seed in ROLL_SEEDS do
		local rolls = makeRolls(seed, ROOM_COUNT)
		for _, scale in SCALES do
			local a = FloorLightPlan.plan(seed, ROOM_COUNT, scale, rolls)
			local b = FloorLightPlan.plan(seed, ROOM_COUNT, scale, rolls)
			expect.deepEq(a, b, `seed {seed} scale {scale} plan stable`)
		end
	end
end)

test("constants of record (hard floor 0.50, target 0.72)", function()
	expect.eq(FloorLightPlan.MIN_LIT_FRACTION, 0.50, "MIN_LIT_FRACTION")
	expect.eq(FloorLightPlan.LIT_TARGET_FRACTION, 0.72, "LIT_TARGET_FRACTION")
end)

return { name = "floor light plan (FloorLightPlan)", tests = tests }
