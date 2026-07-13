--!strict
-- CRYPTLINGS: NIGHT SHIFT — admin allowlist + command rate limit of record
-- (R4-1, LOBBY_SOP_ADDENDUM_3; LOBBY_BUILD_PLAN_R4 WP1.1).
--
-- PERMANENT admins ship by editing this file and deploying — there is no
-- persistence layer for adminship BY DESIGN (a save/load path would add
-- failure modes and security surface to what is a test tool; session grants
-- via /admin live in AdminService memory and die with the server).
--
-- Consumed by AdminService (IsAdmin layer 3) and AdminCommands (token bucket:
-- RateLimit.max commands per RateLimit.windowSec seconds, per user).
-- Pure Luau: requires no Roblox globals (lune-safe; tests/suites/admin_config
-- pins these exact values).

return table.freeze({
	Admins = table.freeze({
		[85875119] = true, -- creator
	}) :: { [number]: boolean },
	RateLimit = table.freeze({ max = 5, windowSec = 10 }),
})
