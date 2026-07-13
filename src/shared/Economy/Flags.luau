--!strict
-- CRYPTLINGS: NIGHT SHIFT — server-respected economy flags (CONTRACTS v1 §F).
-- The §4.4 split-testing home: split cohorts by server via these values.
-- Servers read flags at runtime; ship changes as commits to this file (the
-- economy module is versioned and never hand-edited live — SOP §1.5, §8.2).
-- Pure Luau: requires no Roblox globals (lune-safe).

export type EconomyFlags = {
	whaleBundlesLive: boolean,
	vipLockerPublic: boolean,
	starterPackEnabled: boolean,
	toyLineEndsAt: number,
}

local Flags: EconomyFlags = {
	-- CASE_BUNDLE_XL / CASE_BUNDLE_WHALE ship launch+2wk per §4.1.
	whaleBundlesLive = false,
	-- VIP Locker is a beta-test SKU (§3.3); public release launch+2wk per §4.1.
	vipLockerPublic = false,
	starterPackEnabled = true,
	-- Unix time the current toy line ends. 0 => derive from GameConstants
	-- (TOYLINE_SEASON_SECONDS from season start).
	toyLineEndsAt = 0,
}

-- Intentionally NOT frozen: server-side split-test tooling may flip flags for a
-- cohort at runtime (§4.4). Clients must never trust these values directly.
return Flags
