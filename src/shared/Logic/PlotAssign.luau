--!strict
-- CRYPTLINGS: NIGHT SHIFT — pure plot-assignment core (lobby SOP §3.2;
-- LOBBY_BUILD_PLAN WP1.2). Extracted ahead of LobbyPlotService so the
-- double-claim race guards are testable headless.
--
-- Pure Luau: requires no Roblox globals (lune-safe) and contains NO yields by
-- construction — every function is a single synchronous pass over plain
-- tables, so "find vacant" and "mark owned" can never be interleaved by
-- another caller (the Grow-a-Garden double-claim fix). LobbyPlotService
-- remains the server authority — it owns Player instances, attributes,
-- PersistentPerPlayer, signals, and the spawn flow; every ownership decision
-- it makes goes through the functions in this module:
--
--   new(plotCount) -> State
--   assign(state, playerKey) -> index?
--       Lowest vacant index, atomic find-and-mark. Idempotent: a key that
--       already owns a plot gets its existing index back (never a second
--       plot). Returns nil when the street is full.
--   release(state, playerKey) -> index?
--       Frees the key's plot (nil if it owned none). Freed indices are reused
--       lowest-first by later assigns.
--   sweep(state, livePlayerKeys) -> releasedIndices
--       Releases every owner NOT in the live set — the hard-disconnect
--       backstop behind PlayerRemoving (callers pass Players:GetPlayers()).
--   ownerOf(state, index) -> playerKey?   /   indexOf(state, playerKey) -> index?
--
-- Keys are opaque (the live service uses Player instances; tests use strings)
-- — this module only ever compares them by identity.

export type State = {
	plotCount: number,
	owners: { [number]: any }, -- plot index -> owning key (sparse; nil = vacant)
	indexByKey: { [any]: number }, -- owning key -> plot index (reverse map)
}

local PlotAssign = {}

-- Fresh all-vacant street of `plotCount` plots (lobby of record: 20).
function PlotAssign.new(plotCount: number): State
	assert(
		type(plotCount) == "number" and plotCount >= 0 and plotCount % 1 == 0,
		"PlotAssign.new: plotCount must be a non-negative integer"
	)
	return {
		plotCount = plotCount,
		owners = {},
		indexByKey = {},
	}
end

-- Claims the lowest vacant index for playerKey. The find and the mark happen
-- in the same synchronous step — no yield can sit between them. Idempotent
-- for an already-housed key; nil when full (unreachable in production:
-- MaxPlayers 20 == 20 lots) or for a nil key.
function PlotAssign.assign(state: State, playerKey: any): number?
	if playerKey == nil then
		return nil
	end
	local existing = state.indexByKey[playerKey]
	if existing ~= nil then
		return existing -- double-assign (PlayerAdded + startup sweep race): keep the plot
	end
	for index = 1, state.plotCount do
		if state.owners[index] == nil then
			state.owners[index] = playerKey -- mark immediately: atomic find-and-mark
			state.indexByKey[playerKey] = index
			return index
		end
	end
	return nil -- street full
end

-- Releases playerKey's plot and returns the freed index (nil = owned none —
-- release/sweep/PlayerRemoving overlap is a harmless no-op).
function PlotAssign.release(state: State, playerKey: any): number?
	if playerKey == nil then
		return nil
	end
	local index = state.indexByKey[playerKey]
	if index == nil then
		return nil
	end
	state.indexByKey[playerKey] = nil
	state.owners[index] = nil
	return index
end

-- Hard-disconnect backstop: releases every owner not present in
-- livePlayerKeys and returns the freed indices in ascending order. Live
-- owners are untouched, as is the countdown of anything around them — a
-- sweep only ever removes ghosts.
function PlotAssign.sweep(state: State, livePlayerKeys: { any }): { number }
	local live: { [any]: boolean } = {}
	for _, key in livePlayerKeys do
		live[key] = true
	end

	local released: { number } = {}
	for index = 1, state.plotCount do
		local owner = state.owners[index]
		if owner ~= nil and live[owner] ~= true then
			state.owners[index] = nil
			state.indexByKey[owner] = nil
			table.insert(released, index)
		end
	end
	return released
end

-- Lookup: who owns plot `index`? (nil = vacant or out of range)
function PlotAssign.ownerOf(state: State, index: number): any
	return state.owners[index]
end

-- Lookup: which plot does playerKey own? (nil = none)
function PlotAssign.indexOf(state: State, playerKey: any): number?
	if playerKey == nil then
		return nil
	end
	return state.indexByKey[playerKey]
end

return table.freeze(PlotAssign)
