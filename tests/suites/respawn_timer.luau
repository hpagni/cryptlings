--!strict
-- Respawn-timer state machine suite (Fix #4 — respawn skip). Pins the PURE
-- deadline + pending-flag logic that ShiftService's startRespawnTimer /
-- RespawnNow / clearRespawnState (player-removing) implement on the server.
-- No Roblox APIs: the machine below mirrors the server's bookkeeping exactly
-- (a per-player respawnAt deadline + a respawnPending flag + a "did we load a
-- character" side-effect counter standing in for player:LoadCharacter()).
-- Style after tests/suites/rarity_odds.luau.

local expect = require("../expect")

local tests = {}
local function test(name: string, fn: () -> ())
	table.insert(tests, { name = name, fn = fn })
end

local RESPAWN_WAIT_SECONDS = 5

-- A faithful, pure mirror of the server state machine. `now` is injectable so
-- the deadline math is deterministic (the server uses
-- workspace:GetServerTimeNow()). `respawned` counts doRespawn side-effects
-- (server: player:LoadCharacter()) so we can assert a skip actually fires the
-- respawn and a double-skip does NOT fire a second one.
type Machine = {
	respawnAt: number?,
	respawnPending: boolean,
	respawned: number, -- count of doRespawn() side-effects
	now: number,
}

local function newMachine(now: number): Machine
	return { respawnAt = nil, respawnPending = false, respawned = 0, now = now }
end

-- Mirrors startRespawnTimer: idempotent — a pending timer is left in place and
-- never stacked (a second Died cannot create a second LoadCharacter).
local function startTimer(m: Machine)
	if m.respawnPending then
		return
	end
	m.respawnPending = true
	m.respawnAt = m.now + RESPAWN_WAIT_SECONDS
end

-- Mirrors ShiftService.RespawnNow: rejects when no timer is pending; otherwise
-- clears state and fires the respawn.
local function respawnNow(m: Machine): { ok: boolean, err: string? }
	if not m.respawnPending then
		return { ok = false, err = "NO_PENDING_RESPAWN" }
	end
	m.respawnPending = false
	m.respawnAt = nil
	m.respawned += 1
	return { ok = true }
end

-- Mirrors the task.delay firing (or clearRespawnState canceling it). Returns
-- whether the natural timer actually fired a respawn.
local function elapse(m: Machine, seconds: number)
	m.now += seconds
	if m.respawnPending and m.respawnAt ~= nil and m.now >= (m.respawnAt :: number) then
		m.respawnPending = false
		m.respawnAt = nil
		m.respawned += 1
	end
end

-- Mirrors clearRespawnState (onPlayerRemoving): cancel + clear, never respawn.
local function clearState(m: Machine)
	m.respawnPending = false
	m.respawnAt = nil
end

--------------------------------------------------------------------------------

test("starting a timer sets a pending deadline strictly in the future", function()
	local m = newMachine(100)
	startTimer(m)
	expect.ok(m.respawnPending, "timer is pending after start")
	expect.ok(m.respawnAt ~= nil, "respawnAt deadline is set")
	expect.ok((m.respawnAt :: number) > m.now, "deadline is strictly after now")
	expect.eq(m.respawnAt, 105, "deadline == now + RESPAWN_WAIT_SECONDS")
	expect.eq(m.respawned, 0, "no respawn has fired yet")
end)

test("RespawnNow with a pending timer clears it and returns ok", function()
	local m = newMachine(0)
	startTimer(m)
	local result = respawnNow(m)
	expect.eq(result.ok, true, "skip returns ok")
	expect.eq(result.err, nil, "no error on a successful skip")
	expect.ok(not m.respawnPending, "pending flag cleared")
	expect.eq(m.respawnAt, nil, "deadline cleared")
	expect.eq(m.respawned, 1, "skip fired exactly one respawn")
end)

test("RespawnNow with no pending timer rejects NO_PENDING_RESPAWN", function()
	local m = newMachine(0)
	local result = respawnNow(m)
	expect.eq(result.ok, false, "skip rejected when nothing is pending")
	expect.eq(result.err, "NO_PENDING_RESPAWN", "reject reason")
	expect.eq(m.respawned, 0, "no respawn fired on a reject")
end)

test("double-skip is a no-op: the second call rejects NO_PENDING_RESPAWN", function()
	local m = newMachine(0)
	startTimer(m)
	local first = respawnNow(m)
	expect.eq(first.ok, true, "first skip succeeds")
	local second = respawnNow(m)
	expect.eq(second.ok, false, "second skip rejected")
	expect.eq(second.err, "NO_PENDING_RESPAWN", "second reject reason")
	expect.eq(m.respawned, 1, "only ONE respawn fired across the double-skip (no dupe)")
end)

test("starting a timer while one is pending does not create a second", function()
	local m = newMachine(50)
	startTimer(m)
	local firstDeadline = m.respawnAt
	-- A re-entrant Died (or a stray call) must NOT re-arm / re-stamp.
	m.now += 2
	startTimer(m)
	expect.eq(m.respawnAt, firstDeadline, "deadline unchanged by the second start (idempotent)")
	-- Skipping must still fire exactly one respawn, proving there is one timer.
	respawnNow(m)
	expect.eq(m.respawned, 1, "exactly one respawn — never two timers")
end)

test("clearing (player-removing) cancels the pending timer — no respawn fires", function()
	local m = newMachine(0)
	startTimer(m)
	clearState(m)
	expect.ok(not m.respawnPending, "pending cleared by clearState")
	expect.eq(m.respawnAt, nil, "deadline cleared by clearState")
	-- Past the would-be deadline: a canceled timer must NOT fire.
	elapse(m, RESPAWN_WAIT_SECONDS + 10)
	expect.eq(m.respawned, 0, "no respawn after a canceled timer elapses")
	-- And a skip now correctly reports nothing pending.
	local result = respawnNow(m)
	expect.eq(result.err, "NO_PENDING_RESPAWN", "skip after clear rejects")
end)

test("the natural timer fires a respawn once its deadline elapses", function()
	local m = newMachine(0)
	startTimer(m)
	elapse(m, RESPAWN_WAIT_SECONDS - 1)
	expect.eq(m.respawned, 0, "no respawn before the deadline")
	expect.ok(m.respawnPending, "still pending just before the deadline")
	elapse(m, 1)
	expect.eq(m.respawned, 1, "respawn fired at the deadline")
	expect.ok(not m.respawnPending, "pending cleared after the natural fire")
	-- A skip after the natural fire finds nothing pending.
	local result = respawnNow(m)
	expect.eq(result.err, "NO_PENDING_RESPAWN", "skip after natural respawn rejects")
end)

return { name = "respawn timer state machine (Fix #4)", tests = tests }
