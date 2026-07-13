--!strict
-- Plot assignment suite (lobby SOP §3.2; LOBBY_BUILD_PLAN WP1.2). Exercises
-- the SHIPPED Shared.Logic.PlotAssign — the exact pure core LobbyPlotService
-- delegates every ownership decision to — pinning the double-claim race
-- guards, lowest-first reuse, the sweep backstop, and full-server behavior.

local GameConstants = require("../../src/shared/Config/GameConstants")
local PlotAssign = require("../../src/shared/Logic/PlotAssign")
local expect = require("../expect")

local tests = {}
local function test(name: string, fn: () -> ())
	table.insert(tests, { name = name, fn = fn })
end

local PLOTS = GameConstants.HUB_DISPLAY_STATION_COUNT -- 20 lots == MaxPlayers 20

-- Keys are opaque to the core (the live service passes Player instances);
-- the suite uses strings.
local function key(n: number): string
	return `player_{n}`
end

--------------------------------------------------------------------------------

test("new state: every plot vacant, lookups empty", function()
	local state = PlotAssign.new(PLOTS)
	expect.eq(state.plotCount, PLOTS, "plot count of record (20 lots == MaxPlayers)")
	for index = 1, PLOTS do
		expect.eq(PlotAssign.ownerOf(state, index), nil, `plot {index} starts vacant`)
	end
	expect.eq(PlotAssign.indexOf(state, key(1)), nil, "nobody housed yet")
end)

test("assign claims the lowest vacant index nearest the Factory", function()
	local state = PlotAssign.new(PLOTS)
	expect.eq(PlotAssign.assign(state, key(1)), 1, "first joiner gets plot 1")
	expect.eq(PlotAssign.assign(state, key(2)), 2, "second joiner gets plot 2")
	expect.eq(PlotAssign.assign(state, key(3)), 3, "third joiner gets plot 3")
	expect.eq(PlotAssign.ownerOf(state, 2), key(2), "ownerOf agrees")
	expect.eq(PlotAssign.indexOf(state, key(3)), 3, "indexOf agrees")
end)

test("double-assign is idempotent: PlayerAdded + startup sweep never hand out two plots", function()
	local state = PlotAssign.new(PLOTS)
	expect.eq(PlotAssign.assign(state, key(1)), 1, "first assign claims plot 1")
	expect.eq(PlotAssign.assign(state, key(1)), 1, "second assign returns the SAME plot")
	expect.eq(PlotAssign.ownerOf(state, 1), key(1), "plot 1 still theirs")
	expect.eq(PlotAssign.ownerOf(state, 2), nil, "plot 2 was never touched")
	expect.eq(PlotAssign.assign(state, key(2)), 2, "next player still lands on plot 2")
end)

test("no double-claim under interleaved assigns: ownership stays a strict bijection", function()
	local state = PlotAssign.new(PLOTS)
	-- Interleave fresh claims with re-claims of already-housed keys (the shape
	-- of the PlayerAdded/startup-sweep race): no interleaving may steal an
	-- index that was already marked.
	for n = 1, 10 do
		local index = PlotAssign.assign(state, key(n))
		expect.eq(index, n, `key {n} claims the next lowest index`)
		local interloper = PlotAssign.assign(state, key(math.max(1, n - 1)))
		expect.eq(interloper, math.max(1, n - 1), `re-claim by key {n - 1} cannot steal plot {n}`)
	end

	local seenIndex: { [number]: string } = {}
	for n = 1, 10 do
		local index = PlotAssign.indexOf(state, key(n)) :: number
		expect.ok(index ~= nil, `key {n} owns a plot`)
		expect.eq(seenIndex[index], nil, `plot {index} owned exactly once`)
		seenIndex[index] = key(n)
		expect.eq(PlotAssign.ownerOf(state, index), key(n), `forward/reverse maps agree for plot {index}`)
	end
end)

test("release frees the plot and reports its index; unknown key is a nil no-op", function()
	local state = PlotAssign.new(PLOTS)
	PlotAssign.assign(state, key(1))
	PlotAssign.assign(state, key(2))
	PlotAssign.assign(state, key(3))

	expect.eq(PlotAssign.release(state, key(2)), 2, "release returns the freed index")
	expect.eq(PlotAssign.ownerOf(state, 2), nil, "plot 2 vacant again")
	expect.eq(PlotAssign.indexOf(state, key(2)), nil, "reverse map cleared")
	expect.eq(PlotAssign.release(state, key(2)), nil, "double-release is a no-op")
	expect.eq(PlotAssign.release(state, key(99)), nil, "never-housed key is a no-op")
	expect.eq(PlotAssign.ownerOf(state, 1), key(1), "neighbors untouched")
	expect.eq(PlotAssign.ownerOf(state, 3), key(3), "neighbors untouched")
end)

test("assign after release reuses the freed index lowest-first", function()
	local state = PlotAssign.new(PLOTS)
	for n = 1, 5 do
		PlotAssign.assign(state, key(n))
	end
	PlotAssign.release(state, key(4))
	PlotAssign.release(state, key(2))

	expect.eq(PlotAssign.assign(state, key(6)), 2, "lowest freed plot (2) reused first")
	expect.eq(PlotAssign.assign(state, key(7)), 4, "then the next freed plot (4)")
	expect.eq(PlotAssign.assign(state, key(8)), 6, "then the frontier")
end)

test("rejoin after release lands on the lowest vacancy, not the old plot", function()
	local state = PlotAssign.new(PLOTS)
	for n = 1, 3 do
		PlotAssign.assign(state, key(n))
	end
	PlotAssign.release(state, key(1))
	PlotAssign.release(state, key(3))

	-- key(3) rejoins: its old plot 3 is vacant, but plot 1 is lower.
	expect.eq(PlotAssign.assign(state, key(3)), 1, "rejoiner gets the lowest vacancy")
	expect.eq(PlotAssign.ownerOf(state, 3), nil, "old plot stays vacant")
end)

test("sweep releases ghosts only, ascending, and leaves live owners housed", function()
	local state = PlotAssign.new(PLOTS)
	for n = 1, 6 do
		PlotAssign.assign(state, key(n))
	end

	-- keys 2, 4, 5 hard-disconnected (no PlayerRemoving fired).
	local released = PlotAssign.sweep(state, { key(1), key(3), key(6) })
	expect.deepEq(released, { 2, 4, 5 }, "ghost plots released in ascending order")
	for _, n in { 1, 3, 6 } do
		expect.eq(PlotAssign.indexOf(state, key(n)), n, `live key {n} keeps its plot`)
	end
	for _, index in { 2, 4, 5 } do
		expect.eq(PlotAssign.ownerOf(state, index), nil, `plot {index} vacant after sweep`)
	end

	expect.deepEq(PlotAssign.sweep(state, { key(1), key(3), key(6) }), {}, "second sweep finds nothing")
	expect.deepEq(PlotAssign.sweep(state, {}), { 1, 3, 6 }, "empty live set releases everyone")
	expect.eq(PlotAssign.indexOf(state, key(1)), nil, "reverse map cleared by sweep")
end)

test("full server (20/20): 21st assign returns nil; one release reopens exactly one seat", function()
	local state = PlotAssign.new(PLOTS)
	for n = 1, PLOTS do
		expect.eq(PlotAssign.assign(state, key(n)), n, `joiner {n} housed`)
	end
	expect.eq(PlotAssign.assign(state, key(PLOTS + 1)), nil, "21st body gets no plot (street full)")
	expect.eq(PlotAssign.indexOf(state, key(PLOTS + 1)), nil, "nil assign left no ownership behind")
	expect.eq(PlotAssign.assign(state, key(PLOTS)), PLOTS, "full-server re-assign of a housed key still idempotent")

	expect.eq(PlotAssign.release(state, key(7)), 7, "one player leaves")
	expect.eq(PlotAssign.assign(state, key(PLOTS + 1)), 7, "the waiting joiner takes exactly that plot")
	expect.eq(PlotAssign.assign(state, key(PLOTS + 2)), nil, "and the street is full again")
end)

test("nil keys are refused everywhere (never claim, never crash)", function()
	local state = PlotAssign.new(PLOTS)
	expect.eq(PlotAssign.assign(state, nil), nil, "assign(nil) claims nothing")
	expect.eq(PlotAssign.release(state, nil), nil, "release(nil) frees nothing")
	expect.eq(PlotAssign.indexOf(state, nil), nil, "indexOf(nil) is nil")
	expect.eq(PlotAssign.ownerOf(state, 1), nil, "street untouched")
end)

test("zero-plot street is legal and always full", function()
	local state = PlotAssign.new(0)
	expect.eq(PlotAssign.assign(state, key(1)), nil, "no plots, no assignment")
	expect.deepEq(PlotAssign.sweep(state, {}), {}, "sweep of nothing releases nothing")
end)

return { name = "plot assignment (PlotAssign)", tests = tests }
