--!strict
-- Onboarding copy suite (R7 Fix #1/#2/#4 — first-time flow data of record).
-- Pins the SHIPPED kid-friendly copy in Shared.Config.GameConstants (WELCOME
-- panel, EMPTY_STATE clock-in reminders, STARTER_GUIDE subtitles) and the
-- WelcomeGate truth table — the exact pure decision the once-ever welcome flow
-- delegates its show/skip choice to. Pure Lune: no Roblox instance APIs.

local GameConstants = require("../../src/shared/Config/GameConstants")
local WelcomeGate = require("../../src/shared/Logic/WelcomeGate")
local expect = require("../expect")

local tests = {}
local function test(name: string, fn: () -> ())
	table.insert(tests, { name = name, fn = fn })
end

local function nonEmpty(s: any): boolean
	return type(s) == "string" and #s > 0
end

--------------------------------------------------------------------------------

test("WELCOME panel: non-empty TITLE, full-tour body, and a DISMISS label", function()
	local W = GameConstants.WELCOME
	expect.ok(nonEmpty(W.TITLE), "WELCOME.TITLE is a non-empty string")
	-- Body must cover the whole loop: factory / brainrots / locker / podium / pets / house.
	for _, field in { "FACTORY", "BRAINROTS", "LOCKER", "PODIUM", "PETS", "HOUSE" } do
		expect.ok(nonEmpty(W[field]), `WELCOME body covers {field} (non-empty)`)
	end
	expect.ok(nonEmpty(W.DISMISS), "WELCOME has a non-empty DISMISS label")
end)

test("EMPTY_STATE.CLOCK_IN_REMINDER: non-empty toast, <= 40 chars", function()
	local reminder = GameConstants.EMPTY_STATE.CLOCK_IN_REMINDER
	expect.ok(nonEmpty(reminder), "CLOCK_IN_REMINDER is a non-empty string")
	expect.ok(#reminder <= 40, `CLOCK_IN_REMINDER fits the toast (<=40 chars, got {#reminder})`)
end)

test("empty-state copy always points home: each contains the literal FACTORY", function()
	local E = GameConstants.EMPTY_STATE
	for _, field in { "CLOCK_IN_REMINDER", "LOCKER_EMPTY", "PETS_EMPTY", "PODIUM_EMPTY" } do
		expect.ok(nonEmpty(E[field]), `EMPTY_STATE.{field} is a non-empty string`)
		expect.ok(string.find(E[field], "FACTORY", 1, true) ~= nil, `EMPTY_STATE.{field} names the FACTORY`)
	end
end)

test("STARTER_GUIDE: every subtitle is a non-empty string", function()
	local G = GameConstants.STARTER_GUIDE
	local any = false
	for key, value in G do
		any = true
		expect.ok(nonEmpty(value), `STARTER_GUIDE.{key} is a non-empty string`)
	end
	expect.ok(any, "STARTER_GUIDE has at least one subtitle")
end)

test("WelcomeGate.shouldShow: pinned truth table (R9 — also requires introFloorDone)", function()
	-- R9: the welcome panel now shows in the hub AFTER the intro floor, so
	-- shouldShow ALSO requires onboarding.introFloorDone == true.
	expect.eq(
		WelcomeGate.shouldShow({ welcomeShown = false, introFloorDone = true }, { firstShiftDone = false }),
		true,
		"brand-new account that finished the intro floor shows the welcome flow"
	)
	expect.eq(
		WelcomeGate.shouldShow({ welcomeShown = false, introFloorDone = false }, { firstShiftDone = false }),
		false,
		"intro floor not done yet -> welcome panel waits"
	)
	expect.eq(
		WelcomeGate.shouldShow({ welcomeShown = true, introFloorDone = true }, { firstShiftDone = false }),
		false,
		"welcome already shown -> skip"
	)
	expect.eq(
		WelcomeGate.shouldShow({ welcomeShown = false, introFloorDone = true }, { firstShiftDone = true }),
		false,
		"veteran (first shift done) -> skip even if welcome flag missing/false"
	)
	expect.eq(
		WelcomeGate.shouldShow({ welcomeShown = true, introFloorDone = true }, { firstShiftDone = true }),
		false,
		"settled account -> skip"
	)
end)

test("INTRO: every player-facing copy line is a non-empty string", function()
	local I = GameConstants.INTRO
	for _, field in
		{
			"GRAB_FIRST",
			"GRAB_MORE",
			"CHASE_TELEGRAPH",
			"RUN_TO_EXIT",
			"BUMP_NUDGE",
			"STUCK_HINT",
			"REACHED_EXIT",
			"EXIT_MARKER",
			"BOX_MARKER",
		}
	do
		expect.ok(nonEmpty(I[field]), `INTRO.{field} is a non-empty string`)
	end
end)

return { name = "onboarding copy (WELCOME / EMPTY_STATE / STARTER_GUIDE / WelcomeGate)", tests = tests }
