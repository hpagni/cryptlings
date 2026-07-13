--!strict
-- CRYPTLINGS: NIGHT SHIFT — headless time-math sanity test (Stage 3 "Locker +
-- 3-free-opens/day"). Pure Luau; run from the repo root with:
--   lune run tests/rotation-math.luau
-- Exercises the SHIPPED pure math behind RotationService and the locker daily
-- reset — Util.UnixDay / Util.NextDayBoundary / Util.NextGridBoundary — with
-- injected clocks (no os.time stubbing), plus the §G constants of record
-- (TOYLINE_EPOCH_ANCHOR, TOYLINE_SEASON_SECONDS, SECONDS_PER_DAY).
-- RotationService.GetNightlySeed/GetNightlyRotationAt/GetToyLineEndsAt are
-- thin delegates over these exact functions and constants.

local GameConstants = require("../src/shared/Config/GameConstants")
local Util = require("../src/shared/Util")

local DAY = GameConstants.SECONDS_PER_DAY
local ANCHOR = GameConstants.TOYLINE_EPOCH_ANCHOR
local SEASON = GameConstants.TOYLINE_SEASON_SECONDS

local failures = 0
local function check(condition: boolean, label: string)
	if condition then
		print(`  ok   {label}`)
	else
		failures += 1
		print(`  FAIL {label}`)
	end
end

--------------------------------------------------------------------------------
print("[1] Constants of record")
--------------------------------------------------------------------------------
check(DAY == 86400, "SECONDS_PER_DAY = 86400")
check(ANCHOR == 1767225600, "TOYLINE_EPOCH_ANCHOR = 1767225600 (2026-01-01T00:00:00Z)")
check(ANCHOR % DAY == 0, "anchor sits exactly on a unix-day boundary")
check(SEASON == 6 * 7 * DAY, "TOYLINE_SEASON_SECONDS = 6 weeks")

--------------------------------------------------------------------------------
print("[2] Nightly seed (Util.UnixDay) flips exactly at 00:00 UTC")
--------------------------------------------------------------------------------
local someDay = 20593 -- arbitrary unix day
local midnight = someDay * DAY
check(Util.UnixDay(midnight - 1) == someDay - 1, "1s before midnight -> previous day's seed")
check(Util.UnixDay(midnight) == someDay, "exactly midnight -> new seed")
check(Util.UnixDay(midnight + DAY - 1) == someDay, "23:59:59 -> same seed all day")
check(Util.UnixDay(midnight + DAY) == someDay + 1, "next midnight -> next seed")

--------------------------------------------------------------------------------
print("[3] Nightly rotation (Util.NextDayBoundary) is the next 00:00 UTC, strictly future")
--------------------------------------------------------------------------------
check(Util.NextDayBoundary(midnight) == midnight + DAY, "on the boundary -> the following boundary")
check(Util.NextDayBoundary(midnight + 1) == midnight + DAY, "1s after midnight -> same deadline")
check(Util.NextDayBoundary(midnight + DAY - 1) == midnight + DAY, "1s before the flip -> that flip")
for _, t in { midnight, midnight + 12345, midnight + DAY - 1 } do
	local boundary = Util.NextDayBoundary(t)
	check(boundary > t and boundary % DAY == 0, `boundary after {t} is future and day-aligned`)
end

--------------------------------------------------------------------------------
print("[4] Toy-line grid (Util.NextGridBoundary) is deterministic and strictly future")
--------------------------------------------------------------------------------
check(Util.NextGridBoundary(ANCHOR, SEASON, ANCHOR - 1) == ANCHOR, "pre-anchor clock -> the anchor itself")
check(
	Util.NextGridBoundary(ANCHOR, SEASON, ANCHOR - 10 * SEASON) == ANCHOR - 9 * SEASON,
	"deep pre-anchor clock still lands on the grid"
)
check(Util.NextGridBoundary(ANCHOR, SEASON, ANCHOR) == ANCHOR + SEASON, "exactly on a boundary -> the NEXT one")
check(Util.NextGridBoundary(ANCHOR, SEASON, ANCHOR + 1) == ANCHOR + SEASON, "1s into a season -> its end")
check(
	Util.NextGridBoundary(ANCHOR, SEASON, ANCHOR + SEASON - 1) == ANCHOR + SEASON,
	"last second of a season -> its end"
)

-- Every moment inside season k agrees on one deadline (cross-server determinism).
local seasonIndex = 4
local seasonStart = ANCHOR + seasonIndex * SEASON
local expectedEnd = seasonStart + SEASON
local agreed = true
for offset = 0, SEASON - 1, SEASON // 97 do
	if Util.NextGridBoundary(ANCHOR, SEASON, seasonStart + offset) ~= expectedEnd then
		agreed = false
		break
	end
end
check(agreed, `every clock inside season {seasonIndex} resolves the same endsAt`)

-- Boundaries are always anchor + k * SEASON for integer k.
local sampled = Util.NextGridBoundary(ANCHOR, SEASON, ANCHOR + 1234567)
check((sampled - ANCHOR) % SEASON == 0, "returned boundary sits on the anchor grid")

--------------------------------------------------------------------------------
print("[5] Locker day-flip scenario (Stage 4 Locker.spec shape)")
--------------------------------------------------------------------------------
-- A player who spent their opens yesterday: lastResetDay < UnixDay(now) means
-- EnsureDailyReset will flip and restore the allowance.
local yesterday = someDay - 1
check(Util.UnixDay(midnight + 5) > yesterday, "stale lastResetDay reads as flip-due after midnight")
check(
	(yesterday + 1) * DAY == midnight,
	"nextResetAt formula (lastResetDay + 1) * SECONDS_PER_DAY lands on the flip moment"
)

--------------------------------------------------------------------------------
if failures > 0 then
	print(`rotation-math: {failures} FAILURE(S)`)
	error(`{failures} check(s) failed`, 0)
end
print("rotation-math: all checks passed")
