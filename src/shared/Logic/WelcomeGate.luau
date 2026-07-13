--!strict
-- CRYPTLINGS: NIGHT SHIFT — WelcomeGate (R7 Fix #1 + Fix #4 unified first-time flow).
-- Pure decision logic for the once-ever welcome panel / starter-case grant. No
-- Roblox globals: requires nothing, so it is directly testable headless under Lune.
--
-- The unified first-time flow runs ONCE EVER per account and is SEPARATE from the
-- in-shift OnboardingBeat (stats.firstShiftDone). It shows only for a brand-new
-- account: one that has never seen the welcome panel AND has never finished a
-- first shift. A veteran who somehow lacks the welcome flag (e.g. a profile from
-- before R7) still gets NOTHING here, because firstShiftDone is already true.

local WelcomeGate = {}

-- Minimal shapes (kept local so this module needs no Types require / Roblox env).
export type OnboardingFlags = { welcomeShown: boolean, introFloorDone: boolean }
export type StatsFlags = { firstShiftDone: boolean }

-- R9 (intro floor): true only when a brand-new account should ENTER the intro
-- floor on first load: never seen the welcome panel, never finished a first
-- shift, AND has not already cleared the intro floor. Fail-closed: any
-- non-table / missing field reads as "already settled" (do not enter).
function WelcomeGate.shouldEnterIntro(onboarding: OnboardingFlags?, stats: StatsFlags?): boolean
	if type(onboarding) ~= "table" or type(stats) ~= "table" then
		return false
	end
	return onboarding.welcomeShown == false
		and stats.firstShiftDone == false
		and onboarding.introFloorDone == false
end

-- True only when the welcome flow should fire: the panel has never been shown,
-- the player has never completed an in-shift onboarding, AND the intro floor is
-- already done (R9: the welcome panel shows in the hub AFTER the intro floor).
-- Fail-closed: any non-table / missing field reads as "already settled".
function WelcomeGate.shouldShow(onboarding: OnboardingFlags?, stats: StatsFlags?): boolean
	if type(onboarding) ~= "table" or type(stats) ~= "table" then
		return false
	end
	return onboarding.welcomeShown == false
		and stats.firstShiftDone == false
		and onboarding.introFloorDone == true
end

return WelcomeGate
