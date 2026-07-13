--!strict
-- Intro gate suite (R9 — intro floor decision logic of record). Exhaustively
-- pins WelcomeGate.shouldEnterIntro and WelcomeGate.shouldShow over the full
-- boolean cube of {welcomeShown, firstShiftDone, introFloorDone}, proves a
-- veteran NEVER enters the intro, and proves both gates fail-closed on non-table
-- input. Pure Lune: no Roblox instance APIs.

local WelcomeGate = require("../../src/shared/Logic/WelcomeGate")
local expect = require("../expect")

local tests = {}
local function test(name: string, fn: () -> ())
	table.insert(tests, { name = name, fn = fn })
end

local BOOLS = { false, true }

--------------------------------------------------------------------------------

test("shouldEnterIntro: exhaustive boolean cube (only brand-new + intro-not-done enters)", function()
	for _, welcomeShown in BOOLS do
		for _, firstShiftDone in BOOLS do
			for _, introFloorDone in BOOLS do
				local onboarding = { welcomeShown = welcomeShown, introFloorDone = introFloorDone }
				local stats = { firstShiftDone = firstShiftDone }
				local want = (welcomeShown == false) and (firstShiftDone == false) and (introFloorDone == false)
				expect.eq(
					WelcomeGate.shouldEnterIntro(onboarding, stats),
					want,
					`shouldEnterIntro w={tostring(welcomeShown)} f={tostring(firstShiftDone)} i={tostring(introFloorDone)}`
				)
			end
		end
	end
end)

test("shouldShow: exhaustive boolean cube (R9 — also requires introFloorDone==true)", function()
	for _, welcomeShown in BOOLS do
		for _, firstShiftDone in BOOLS do
			for _, introFloorDone in BOOLS do
				local onboarding = { welcomeShown = welcomeShown, introFloorDone = introFloorDone }
				local stats = { firstShiftDone = firstShiftDone }
				local want = (welcomeShown == false) and (firstShiftDone == false) and (introFloorDone == true)
				expect.eq(
					WelcomeGate.shouldShow(onboarding, stats),
					want,
					`shouldShow w={tostring(welcomeShown)} f={tostring(firstShiftDone)} i={tostring(introFloorDone)}`
				)
			end
		end
	end
end)

test("veteran (firstShiftDone==true) NEVER enters the intro", function()
	for _, welcomeShown in BOOLS do
		for _, introFloorDone in BOOLS do
			local onboarding = { welcomeShown = welcomeShown, introFloorDone = introFloorDone }
			expect.eq(
				WelcomeGate.shouldEnterIntro(onboarding, { firstShiftDone = true }),
				false,
				`veteran never enters intro (w={tostring(welcomeShown)} i={tostring(introFloorDone)})`
			)
		end
	end
end)

test("both gates fail-closed on non-table / missing input", function()
	local goodOnboarding = { welcomeShown = false, introFloorDone = false }
	local goodStats = { firstShiftDone = false }

	-- nil is checked explicitly (a nil array element would break ipairs length).
	expect.eq(WelcomeGate.shouldEnterIntro(nil, goodStats), false, "shouldEnterIntro fail-closed on nil onboarding")
	expect.eq(WelcomeGate.shouldEnterIntro(goodOnboarding, nil), false, "shouldEnterIntro fail-closed on nil stats")
	expect.eq(WelcomeGate.shouldShow(nil, goodStats), false, "shouldShow fail-closed on nil onboarding")
	expect.eq(WelcomeGate.shouldShow(goodOnboarding, nil), false, "shouldShow fail-closed on nil stats")

	for _, bad in { 0, "x", true } :: { any } do
		expect.eq(WelcomeGate.shouldEnterIntro(bad, goodStats), false, "shouldEnterIntro fail-closed on bad onboarding")
		expect.eq(WelcomeGate.shouldEnterIntro(goodOnboarding, bad), false, "shouldEnterIntro fail-closed on bad stats")
		expect.eq(WelcomeGate.shouldShow(bad, goodStats), false, "shouldShow fail-closed on bad onboarding")
		expect.eq(WelcomeGate.shouldShow(goodOnboarding, bad), false, "shouldShow fail-closed on bad stats")
	end
end)

return { name = "intro gate (WelcomeGate.shouldEnterIntro / shouldShow cube)", tests = tests }
