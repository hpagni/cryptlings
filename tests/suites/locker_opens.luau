--!strict
-- Locker daily-opens suite (SOP §3.1 ③ "3-free-opens/day", §1.2 — the 24-48h
-- return-habit engine). Exercises the SHIPPED Shared.Logic.LockerCore — the
-- exact module LockerService.TryConsumeOpen and PlayerDataService's
-- EnsureDailyReset delegate to — plus the Util day-boundary math it keys on.

local GameConstants = require("../../src/shared/Config/GameConstants")
local LockerCore = require("../../src/shared/Logic/LockerCore")
local expect = require("../expect")

local tests = {}
local function test(name: string, fn: () -> ())
	table.insert(tests, { name = name, fn = fn })
end

local FREE = GameConstants.FREE_OPENS_PER_DAY -- 30 (playtest tuning; "per day" = per reset window)
local VIP = GameConstants.VIP_OPENS_PER_DAY -- 60
local WINDOW = GameConstants.LOCKER_RESET_WINDOW_SECONDS -- the allowance window (4h)
local TODAY = 20600 -- arbitrary fixed reset-window index; suites never read the wall clock

local function newLocker(overrides: { [string]: any }?): any
	local locker = { cases = {}, freeOpensUsed = 0, lastResetDay = TODAY, extraOpenCredits = 0 }
	for key, value in overrides or {} do
		locker[key] = value
	end
	return locker
end

--------------------------------------------------------------------------------

test("allowance dials: 30 free per window, 60 with the VIP Locker pass", function()
	expect.eq(FREE, 30, "FREE_OPENS_PER_DAY of record (playtest tuning)")
	expect.eq(VIP, 60, "VIP_OPENS_PER_DAY of record (playtest tuning)")
	expect.eq(LockerCore.OpensPerDay(false), FREE, "non-VIP allowance")
	expect.eq(LockerCore.OpensPerDay(true), VIP, "VIP allowance")
end)

test("3 free opens consume, the 4th is blocked with remaining == 0", function()
	local locker = newLocker()
	for press = 1, FREE do
		local consumed, remaining = LockerCore.ConsumeOpen(locker, FREE, TODAY)
		expect.eq(consumed, true, `open #{press} consumed`)
		expect.eq(remaining, FREE - press, `remaining after open #{press}`)
	end
	expect.eq(locker.freeOpensUsed, FREE, "all free opens spent")

	local blocked, remaining = LockerCore.ConsumeOpen(locker, FREE, TODAY)
	expect.eq(blocked, false, "4th open blocked (locker_cap_hit)")
	expect.eq(remaining, 0, "nothing left today")
	expect.eq(locker.freeOpensUsed, FREE, "block consumed nothing")
end)

test("purchased extra opens: consumed only AFTER the day's free opens run dry", function()
	local locker = newLocker({ extraOpenCredits = 2 })
	for press = 1, FREE do
		local consumed = LockerCore.ConsumeOpen(locker, FREE, TODAY)
		expect.eq(consumed, true, `free open #{press}`)
		expect.eq(locker.extraOpenCredits, 2, `credits untouched while free opens remain (#{press})`)
	end

	local consumed4, remaining4 = LockerCore.ConsumeOpen(locker, FREE, TODAY)
	expect.ok(consumed4 and remaining4 == 1, "4th open spends a credit (EXTRA_OPENING product)")
	expect.eq(locker.extraOpenCredits, 1, "one credit left")

	local consumed5, remaining5 = LockerCore.ConsumeOpen(locker, FREE, TODAY)
	expect.ok(consumed5 and remaining5 == 0, "5th open spends the last credit")

	local blocked, remaining6 = LockerCore.ConsumeOpen(locker, FREE, TODAY)
	expect.ok(not blocked and remaining6 == 0, "6th open blocked: free + credits exhausted")
end)

test("daily reset restores free opens but never touches purchased credits", function()
	local locker = newLocker({ freeOpensUsed = FREE, extraOpenCredits = 2, lastResetDay = TODAY })
	expect.eq(LockerCore.EnsureDailyReset(locker, TODAY), false, "same day: no reset")
	expect.eq(locker.freeOpensUsed, FREE, "spent opens stay spent within the day")

	expect.eq(LockerCore.EnsureDailyReset(locker, TODAY + 1), true, "next unix day: reset applies")
	expect.eq(locker.freeOpensUsed, 0, "free opens restored")
	expect.eq(locker.lastResetDay, TODAY + 1, "reset day stamped")
	expect.eq(locker.extraOpenCredits, 2, "credits never expire (§4.2)")

	expect.eq(LockerCore.EnsureDailyReset(locker, TODAY + 1), false, "reset is once per day")
end)

test("paid allowance refill (OPENS_RESET): zeroes spent opens, never touches credits", function()
	local locker = newLocker({ freeOpensUsed = FREE, extraOpenCredits = 2 })
	LockerCore.ResetAllowance(locker, TODAY)
	expect.eq(locker.freeOpensUsed, 0, "spent opens refunded immediately")
	expect.eq(locker.lastResetDay, TODAY, "current window stamped")
	expect.eq(locker.extraOpenCredits, 2, "purchased credits untouched")
	expect.eq(LockerCore.EnsureDailyReset(locker, TODAY), false, "no double reset within the window")

	local consumed, remaining = LockerCore.ConsumeOpen(locker, FREE, TODAY)
	expect.ok(consumed and remaining == FREE - 1 + 2, "full allowance is back after the refill")
end)

test("reset boundary is the window flip (LOCKER_RESET_WINDOW_SECONDS), via the shipped clock math", function()
	local flipAt = (TODAY + 1) * WINDOW
	expect.eq(LockerCore.WindowIndex(flipAt - 1), TODAY, "1s before the flip is still the old window")
	expect.eq(LockerCore.WindowIndex(flipAt), TODAY + 1, "the flip second starts the new window")
	expect.eq(LockerCore.NextResetAt(TODAY), flipAt, "nextResetAt formula lands exactly on the flip")

	-- A player who spent everything just before the flip opens again right at
	-- it — the consume path itself applies the reset (the LockerService Update
	-- closure passes WindowIndex(os.time())).
	local locker = newLocker({ freeOpensUsed = FREE })
	local blocked = LockerCore.ConsumeOpen(locker, FREE, LockerCore.WindowIndex(flipAt - 1))
	expect.eq(blocked, false, "exhausted just before the flip")
	local consumed, remaining = LockerCore.ConsumeOpen(locker, FREE, LockerCore.WindowIndex(flipAt))
	expect.ok(consumed and remaining == FREE - 1, "first open of the new window consumed")
	expect.eq(locker.lastResetDay, TODAY + 1, "consume stamped the new window")
end)

test("multi-day absence resets once; future-dated lastResetDay never resets (clock-skew safe)", function()
	local locker = newLocker({ freeOpensUsed = 2, lastResetDay = TODAY - 7 })
	local consumed, remaining = LockerCore.ConsumeOpen(locker, FREE, TODAY)
	expect.ok(consumed and remaining == FREE - 1, "a week away still yields exactly one fresh allowance")
	expect.eq(locker.lastResetDay, TODAY, "stamped to today, not today-6")

	local skewed = newLocker({ freeOpensUsed = FREE, lastResetDay = TODAY + 2 })
	expect.eq(LockerCore.EnsureDailyReset(skewed, TODAY), false, "future stamp: no reset")
	expect.eq((LockerCore.ConsumeOpen(skewed, FREE, TODAY)), false, "and no free allowance minted")
end)

test("VIP locker: 6 opens/day through the same consume path", function()
	local locker = newLocker({ extraOpenCredits = 1 })
	local perDay = LockerCore.OpensPerDay(true)
	for press = 1, VIP do
		local consumed, remaining = LockerCore.ConsumeOpen(locker, perDay, TODAY)
		expect.eq(consumed, true, `VIP open #{press}`)
		expect.eq(remaining, VIP - press + 1, `remaining after VIP open #{press} includes the credit`)
	end
	local consumed7, remaining7 = LockerCore.ConsumeOpen(locker, perDay, TODAY)
	expect.ok(consumed7 and remaining7 == 0, "7th VIP open spends the purchased credit")
	expect.eq((LockerCore.ConsumeOpen(locker, perDay, TODAY)), false, "8th blocked")
end)

test("losing VIP mid-day cannot mint opens (remaining math clamps at 0)", function()
	-- VIP player spent more than the free allowance, then the pass answer flips
	-- to non-VIP (cache refresh): freeOpensUsed now exceeds perDay (FREE).
	local locker = newLocker({ freeOpensUsed = FREE + 2 })
	local consumed, remaining = LockerCore.ConsumeOpen(locker, FREE, TODAY)
	expect.eq(consumed, false, "over-cap player gets no free open")
	expect.eq(remaining, 0, "remaining clamps at 0, never negative")
end)

return { name = "locker daily opens (LockerCore)", tests = tests }
