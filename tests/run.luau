--!strict
-- CRYPTLINGS: NIGHT SHIFT — headless test runner (QA gate; SOP §8.1/§8.2).
-- Runs every assert-based suite against the PURE game logic (Shared.Config /
-- Shared.Economy / Shared.Logic — the exact modules the live services execute)
-- under Lune. No Roblox instance APIs are touched.
--
--   lune run tests/run
--
-- Exits nonzero with a FAIL summary if any test fails; prints PASS otherwise.
-- The two standalone sims (tests/rarity-sim.luau, tests/rotation-math.luau)
-- remain runnable on their own and cover the economy data of record + time
-- math; this runner is the per-behavior unit gate.

local process = require("@lune/process")

type Test = { name: string, fn: () -> () }
type Suite = { name: string, tests: { Test } }

local suites: { Suite } = {
	require("./suites/rarity_odds"),
	require("./suites/price_ladder"),
	require("./suites/trade_fsm"),
	require("./suites/locker_opens"),
	require("./suites/pet_perks"),
	require("./suites/plot_assign"),
	require("./suites/dispatch_core"), -- R2 metronome (the retired queue-pad FSM's replacement of record)
	require("./suites/house_transitions"),
	require("./suites/lobby_budget"),
	require("./suites/house_stairs"), -- R5 stair core (WP1.3; AC-R5.3 mechanized as pure plan math)
	require("./suites/admin_config"), -- R4 admin allowlist + /unlockall housing-chain data pins
	require("./suites/floor_light_plan"),
	require("./suites/trade_picker_tiers"),
	require("./suites/respawn_timer"),
	require("./suites/onboarding_copy"), -- R7 first-time flow copy + WelcomeGate truth table
	require("./suites/intro_gate"), -- R9 intro floor WelcomeGate.shouldEnterIntro/shouldShow cube
}

local passed = 0
local failed = 0
local failures: { string } = {}

local startedAt = os.clock()
for _, suite in suites do
	print(`\n== {suite.name} ==`)
	for _, test in suite.tests do
		local ok, err = pcall(test.fn)
		if ok then
			passed += 1
			print(`  ok   {test.name}`)
		else
			failed += 1
			print(`  FAIL {test.name}`)
			print(`       {tostring(err)}`)
			table.insert(failures, `{suite.name} :: {test.name}`)
		end
	end
end

local elapsed = os.clock() - startedAt
print(`\n{passed + failed} tests, {passed} passed, {failed} failed ({string.format("%.2f", elapsed)}s)`)
if failed > 0 then
	print("FAILED:")
	for _, name in failures do
		print(`  - {name}`)
	end
	print("tests/run: FAIL")
	process.exit(1)
end
print("tests/run: PASS")
