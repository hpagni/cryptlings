--!strict
-- CRYPTLINGS: NIGHT SHIFT — pure locker daily-opens core (Stage 3 "Locker +
-- 3-free-opens/day"; SOP §3.1 ③, §1.2). Extracted from PlayerDataService /
-- LockerService so the 24-48h return-habit math is testable headless.
--
-- Pure Luau: requires no Roblox globals (lune-safe). Operates on the
-- profile.locker table (contract §D); callers pass `today` = Util.UnixDay()
-- (or an injected day in tests) and remain responsible for running mutations
-- inside PlayerDataService.Update.

local GameConstants = require("../Config/GameConstants")
local Types = require("../Types")

export type LockerData = {
	cases: { Types.CaseStub },
	freeOpensUsed: number,
	lastResetDay: number, -- unix day = math.floor(os.time() / 86400)
	extraOpenCredits: number,
}

local LockerCore = {}

-- Daily open allowance: FREE_OPENS_PER_DAY (3), or VIP_OPENS_PER_DAY (6) with
-- the PASS_VIP_LOCKER game pass.
function LockerCore.OpensPerDay(ownsVipPass: boolean): number
	return if ownsVipPass then GameConstants.VIP_OPENS_PER_DAY else GameConstants.FREE_OPENS_PER_DAY
end

-- Daily locker reset at the unix-day boundary (00:00 UTC, §G): if a new unix
-- day has started since locker.lastResetDay, zero freeOpensUsed and stamp the
-- new day. extraOpenCredits are purchased/earned and never expire — a reset
-- must not touch them. Returns true when a reset was applied.
function LockerCore.EnsureDailyReset(locker: LockerData, today: number): boolean
	if today > locker.lastResetDay then
		locker.freeOpensUsed = 0
		locker.lastResetDay = today
		return true
	end
	return false
end

-- Attempts to consume one case-opening: daily reset first, then the day's free
-- opens, then purchased extraOpenCredits. Returns
-- (consumed, opensRemaining = freeLeft + credits) reflecting the state AFTER
-- any consumption.
function LockerCore.ConsumeOpen(locker: LockerData, perDay: number, today: number): (boolean, number)
	LockerCore.EnsureDailyReset(locker, today)
	local consumed = false
	if locker.freeOpensUsed < perDay then
		locker.freeOpensUsed += 1
		consumed = true
	elseif locker.extraOpenCredits > 0 then
		locker.extraOpenCredits -= 1
		consumed = true
	end
	local remaining = math.max(0, perDay - locker.freeOpensUsed) + locker.extraOpenCredits
	return consumed, remaining
end

-- Reset-window index (the "day" of the allowance clock). Originally the unix
-- day; now any fixed window (§G LOCKER_RESET_WINDOW_SECONDS, currently 4h).
-- Pure: callers pass now = os.time() (or an injected clock in tests).
function LockerCore.WindowIndex(now: number): number
	return math.floor(now / GameConstants.LOCKER_RESET_WINDOW_SECONDS)
end

-- Unix time the free-open allowance next resets: the window boundary after
-- the last applied reset (contract §C LockerState.nextResetAt).
function LockerCore.NextResetAt(lastResetDay: number): number
	return (lastResetDay + 1) * GameConstants.LOCKER_RESET_WINDOW_SECONDS
end

-- Paid allowance refill (OPENS_RESET product): zero the window's spent opens
-- immediately and stamp the current window. extraOpenCredits are untouched.
function LockerCore.ResetAllowance(locker: LockerData, today: number)
	locker.freeOpensUsed = 0
	locker.lastResetDay = today
end

return table.freeze(LockerCore)
