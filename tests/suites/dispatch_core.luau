--!strict
-- Metronome dispatch suite (R2 WP1.1; Addendum 1 Change 6 §6.1/§6.2).
-- Exercises the SHIPPED Shared.Logic.DispatchCore — the pure core the Wave-5
-- QueuePadService rewrite feeds snapshots into — with an injected clock;
-- suites never read the wall clock. These pins are the named replacement of
-- record for the queue_core suite retired at the Wave-5 cutover (WP5.1): the
-- old FSM's start-on-first-entrant / leave-resets-on-empty / T-1 lock /
-- full-clamp / start-now-early-launch / overflow assertions are superseded
-- one-for-one by the perpetual-epoch / T=0-snapshot / T-3-freeze / FIFO-bins
-- / no-hold-back / AFK-exclusion / vote-extra-dispatch pins below.

local DispatchCore = require("../../src/shared/Logic/DispatchCore")
local GameConstants = require("../../src/shared/Config/GameConstants")
local expect = require("../expect")

local tests = {}
local function test(name: string, fn: () -> ())
	table.insert(tests, { name = name, fn = fn })
end

local CYCLE = GameConstants.INTERMISSION_SECONDS -- 45 (single constant of record)
local EPOCH = 1000 -- arbitrary fixed clock origin

-- N singleton units keyed p1..pN, arriving 1 s apart starting at `firstAt`.
local function singletons(count: number, firstAt: number): { DispatchCore.Unit }
	local units: { DispatchCore.Unit } = {}
	for index = 1, count do
		table.insert(units, { keys = { `p{index}` }, arrivedAt = firstAt + (index - 1) })
	end
	return units
end

--------------------------------------------------------------------------------

test("defaults of record: cycle 45 (== INTERMISSION_SECONDS), bins of 4, 3 s freeze, 5 slots", function()
	expect.eq(CYCLE, 45, "INTERMISSION_SECONDS of record")
	local config = DispatchCore.config()
	expect.eq(config.cycleSeconds, CYCLE, "cycle sourced from GameConstants, no duplicate 45")
	expect.eq(config.binSize, 4, "bin size — max players per floor")
	expect.eq(config.freezeSeconds, 3, "T-3 snapshot freeze")
	expect.eq(config.maxBins, 5, "slot pool cap — max concurrent sessions")

	local custom = DispatchCore.config({ binSize = 2 })
	expect.eq(custom.binSize, 2, "partial override honored")
	expect.eq(custom.cycleSeconds, CYCLE, "unspecified dials keep defaults")
end)

test("perpetual epoch cycle: remaining never resets across dispatches or an empty T=0 (silent rollover)", function()
	expect.eq(DispatchCore.remaining(EPOCH, EPOCH), CYCLE, "fresh epoch reads the full cycle")
	expect.eq(DispatchCore.remaining(EPOCH, EPOCH + 1), CYCLE - 1, "one second in")
	expect.eq(DispatchCore.remaining(EPOCH, EPOCH + CYCLE - 1), 1, "final second of the cycle")
	expect.eq(DispatchCore.remaining(EPOCH, EPOCH + CYCLE), CYCLE, "empty T=0 rolls silently: SAME epoch, next cycle")
	expect.eq(DispatchCore.remaining(EPOCH, EPOCH + 7 * CYCLE + 30), CYCLE - 30, "epoch arithmetic holds cycles later")

	-- A dispatch is a pure read of the snapshot — the clock is untouched.
	local before = DispatchCore.remaining(EPOCH, EPOCH + 10)
	DispatchCore.planDispatch(singletons(6, EPOCH), 5)
	expect.eq(DispatchCore.remaining(EPOCH, EPOCH + 10), before, "dispatching never moves the countdown")
end)

test("snapshot semantics at T=0: a computed plan is immune to post-snapshot mutation", function()
	local units = singletons(5, EPOCH)
	local plan = DispatchCore.planDispatch(units, 5)
	expect.deepEq(plan.bins, { { "p1", "p2", "p3", "p4" }, { "p5" } }, "plan from the frozen snapshot")

	-- Live pad churn after the snapshot must not bleed into the plan.
	table.insert(units[1].keys, "lateJoiner")
	units[2].arrivedAt = EPOCH - 100
	table.remove(units, 5)
	expect.deepEq(plan.bins, { { "p1", "p2", "p3", "p4" }, { "p5" } }, "bins never alias the input tables")
end)

test("6 occupants -> [4][2], both bins the same tick", function()
	local plan = DispatchCore.planDispatch(singletons(6, EPOCH), 5)
	expect.deepEq(plan.bins, { { "p1", "p2", "p3", "p4" }, { "p5", "p6" } }, "one plan, two simultaneous floors")
	expect.deepEq(plan.deferredBins, {}, "nothing defers with free slots")
end)

test("a 5-friend unit splits 4+remainder -> [4][1]", function()
	local party: { DispatchCore.Unit } = {
		{ keys = { "f1", "f2", "f3", "f4", "f5" }, arrivedAt = EPOCH },
	}
	local plan = DispatchCore.planDispatch(party, 5)
	expect.deepEq(
		plan.bins,
		{ { "f1", "f2", "f3", "f4" }, { "f5" } },
		"oversized party splits, remainder still launches"
	)
end)

test("FIFO by pad arrival, never random; ties keep input order", function()
	local units: { DispatchCore.Unit } = {
		{ keys = { "a" }, arrivedAt = EPOCH + 5 },
		{ keys = { "b" }, arrivedAt = EPOCH + 1 },
		{ keys = { "c" }, arrivedAt = EPOCH + 3 },
		{ keys = { "d" }, arrivedAt = EPOCH + 2 },
		{ keys = { "e" }, arrivedAt = EPOCH + 4 },
	}
	local bins = DispatchCore.partition(units, 4)
	expect.deepEq(bins, { { "b", "d", "c", "e" }, { "a" } }, "bins fill by earliest pad arrival")

	local tied: { DispatchCore.Unit } = {
		{ keys = { "x" }, arrivedAt = EPOCH },
		{ keys = { "y" }, arrivedAt = EPOCH },
		{ keys = { "z" }, arrivedAt = EPOCH },
	}
	expect.deepEq(DispatchCore.partition(tied, 4), { { "x", "y", "z" } }, "equal arrivals keep input order (stable)")
end)

test("no group is ever held back: under-filled trailing bins dispatch", function()
	expect.deepEq(
		DispatchCore.partition(singletons(3, EPOCH), 4),
		{ { "p1", "p2", "p3" } },
		"a lone partial bin launches"
	)
	expect.deepEq(
		DispatchCore.partition(singletons(7, EPOCH), 4),
		{ { "p1", "p2", "p3", "p4" }, { "p5", "p6", "p7" } },
		"7 -> [4][3], the trailing 3 never waits for a future cycle"
	)
end)

test("party-aware first-fit: parties of <= 4 are never split across bins", function()
	local units: { DispatchCore.Unit } = {
		{ keys = { "a1", "a2" }, arrivedAt = EPOCH },
		{ keys = { "b1", "b2", "b3" }, arrivedAt = EPOCH + 1 },
		{ keys = { "c1", "c2" }, arrivedAt = EPOCH + 2 },
	}
	local bins = DispatchCore.partition(units, 4)
	expect.deepEq(
		bins,
		{ { "a1", "a2", "c1", "c2" }, { "b1", "b2", "b3" } },
		"the 3-party stays whole; the later pair first-fits the earlier bin"
	)
end)

test("T-3 freeze: late ENTRY locked out, a leave inside the final 3 s still removes", function()
	expect.eq(DispatchCore.inFreeze(EPOCH, EPOCH + CYCLE - 4), false, "T-4: doors still open")
	expect.eq(DispatchCore.inFreeze(EPOCH, EPOCH + CYCLE - 3), true, "T-3: DOORS CLOSING — entry defers")
	expect.eq(DispatchCore.inFreeze(EPOCH, EPOCH + CYCLE - 0.5), true, "frozen through the final tick")
	expect.eq(DispatchCore.inFreeze(EPOCH, EPOCH + CYCLE), false, "rollover instant starts the next open cycle")

	-- Stepping OFF during the freeze still removes: the caller drops the key
	-- from the frozen snapshot before planning. Only late ENTRY locks.
	local snapshot = singletons(4, EPOCH)
	local afterLeave = DispatchCore.excludeKeys(snapshot, { p3 = true })
	local plan = DispatchCore.planDispatch(afterLeave, 5)
	expect.deepEq(plan.bins, { { "p1", "p2", "p4" } }, "freeze-window leaver excluded, rest dispatch intact")
end)

test("AFK-marked keys are excluded from the partition input", function()
	local units: { DispatchCore.Unit } = {
		{ keys = { "f1", "afkFriend", "f3" }, arrivedAt = EPOCH },
		{ keys = { "afkLoner" }, arrivedAt = EPOCH + 1 },
		{ keys = { "solo" }, arrivedAt = EPOCH + 2 },
	}
	local filtered = DispatchCore.excludeKeys(units, { afkFriend = true, afkLoner = true })
	expect.deepEq(
		filtered,
		{ { keys = { "f1", "f3" }, arrivedAt = EPOCH }, { keys = { "solo" }, arrivedAt = EPOCH + 2 } },
		"AFK keys dropped; gutted units removed; arrival stamps preserved"
	)
	expect.deepEq(DispatchCore.partition(filtered, 4), { { "f1", "f3", "solo" } }, "no AFK key ever reaches a bin")
	expect.deepEq(units[1].keys, { "f1", "afkFriend", "f3" }, "filtering never mutates the live units")
end)

test("slot exhaustion: 6 bins over 5 slots defers exactly the 6th", function()
	local plan = DispatchCore.planDispatch(singletons(22, EPOCH), 5)
	expect.eq(#plan.bins, 5, "first five bins take the whole slot pool")
	expect.deepEq(plan.deferredBins, { { "p21", "p22" } }, "ONLY the 6th bin defers — ALL FLOORS RUNNING")

	local clamped = DispatchCore.planDispatch(singletons(22, EPOCH), 9)
	expect.eq(#clamped.bins, 5, "freeSlots clamps to the 5-slot pool")
	expect.deepEq(clamped.deferredBins, { { "p21", "p22" } }, "clamp still defers the overflow bin")

	local starved = DispatchCore.planDispatch(singletons(6, EPOCH), 0)
	expect.deepEq(starved.bins, {}, "zero free slots launches nothing")
	expect.eq(#starved.deferredBins, 2, "every bin defers to the next cycle")
end)

test("vote dispatch never touches the epoch", function()
	local now = EPOCH + 20
	local before = DispatchCore.remaining(EPOCH, now)
	expect.eq(DispatchCore.voteReady({ p1 = true, p2 = true }, { "p1", "p2" }), true, "unanimous vote passes")
	expect.eq(DispatchCore.remaining(EPOCH, now), before, "master countdown unmoved by a vote dispatch")
	expect.eq(DispatchCore.inFreeze(EPOCH, now), false, "clock state fully epoch-derived — no hidden machine")
end)

test("vote set: unanimous over >= 1 occupant; a new entrant breaks stale unanimity until votes are recast", function()
	expect.eq(DispatchCore.voteReady({}, {}), false, "empty pad never vote-launches")
	expect.eq(DispatchCore.voteReady({ p1 = true }, { "p1" }), true, "solo voter is unanimous (min 1)")
	expect.eq(DispatchCore.voteReady({ p1 = true }, { "p1", "p2" }), false, "1/2 votes is not unanimity")

	-- p3 steps on after p1/p2 voted: their stale unanimity must not fire.
	expect.eq(DispatchCore.voteReady({ p1 = true, p2 = true }, { "p1", "p2", "p3" }), false, "new entrant blocks")
	-- Caller clears the vote set on entry; nothing fires until everyone recasts.
	expect.eq(DispatchCore.voteReady({}, { "p1", "p2", "p3" }), false, "cleared votes -> no launch")
	expect.eq(
		DispatchCore.voteReady({ p1 = true, p2 = true, p3 = true }, { "p1", "p2", "p3" }),
		true,
		"full recast restores the launch"
	)
end)

return { name = "metronome dispatch (DispatchCore)", tests = tests }
