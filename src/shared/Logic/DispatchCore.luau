--!strict
-- CRYPTLINGS: NIGHT SHIFT — pure metronome dispatch core (R2 WP1.1; Addendum 1
-- Change 6 §6.1/§6.2). Replaced the retired queue-pad FSM (Shared.Logic,
-- deleted at the Wave-5 cutover): the pad is no longer a start-on-first-entrant
-- machine but a CONSTANT 45 s loop that dispatches EVERY snapshot occupant in
-- party-aware FIFO bins of <= 4.
--
-- Pure Luau: no Roblox globals (lune-safe). There is no state object — the
-- only metronome state is the epoch number, owned by the caller
-- (QueuePadService sets `shiftEpoch = workspace:GetServerTimeNow()` ONCE at
-- Start and never mutates it; tests inject any monotonic clock):
--
--   config(partial?) -> Config                  (defaults from GameConstants)
--   remaining(epoch, now, config?) -> number    (seconds to T=0; (0, cycle])
--   inFreeze(epoch, now, config?) -> boolean    (inside the final 3 s window)
--   excludeKeys(units, excluded) -> {Unit}      (AFK/leaver filter for the
--                                                partition input; empty units
--                                                are dropped)
--   partition(units, binSize) -> { {Key} }      (party-aware FIFO first-fit)
--   planDispatch(occupants, freeSlots, config?) -> DispatchPlan
--   voteReady(votes, occupantKeys) -> boolean   (unanimous Start-now vote)
--
-- Rules of record (each pinned in tests/suites/dispatch_core.luau):
--   * Perpetual epoch cycle: `remaining = cycle - (now - epoch) % cycle`.
--     Never pauses, never resets — not across dispatches, not on an empty pad
--     at T=0 (silent rollover: SAME epoch, next cycle reads the full 45).
--   * Snapshot semantics: the plan computed at T=0 is a value, immune to any
--     later mutation of the live occupant tables (bins never alias input).
--   * Partition is party-aware FIFO first-fit: a unit = co-present friends
--     (v1 party proxy) else a singleton, ordered by earliest pad arrival
--     (never random; ties keep input order); a unit > binSize splits into
--     binSize + remainder chunks; an under-filled trailing bin STILL
--     dispatches — no group is ever held back for a future cycle.
--   * 6 occupants -> [4][2], both bins the same tick.
--   * T-3 freeze (`inFreeze`): late ENTRY defers to the next cycle, but a
--     leave inside the final 3 s still removes (the caller drops the key from
--     the frozen snapshot via `excludeKeys` — only late ENTRY locks).
--   * AFK-marked keys never reach the partition input (`excludeKeys`).
--   * Slot exhaustion: only bins beyond `freeSlots` defer ("ALL FLOORS
--     RUNNING"); freeSlots is clamped to maxBins (5 concurrent sessions).
--   * Start-now vote is unanimous over the CURRENT occupants (>= 1 voter) and
--     never touches the epoch — a vote dispatch is an extra bin, the master
--     clock keeps running. The caller clears the vote set whenever a new key
--     enters the pad (a stale unanimity must never fire).

local GameConstants = require("../Config/GameConstants")

--------------------------------------------------------------------------------
-- Types
--------------------------------------------------------------------------------

-- Tests key by short strings; QueuePadService keys by UserId.
export type Key = string | number

export type Config = {
	cycleSeconds: number, -- 45 (GameConstants.INTERMISSION_SECONDS — single constant of record)
	binSize: number, -- 4: max players per dispatched floor
	freezeSeconds: number, -- 3: snapshot freeze window before T=0
	maxBins: number, -- 5: concurrent-session slot pool size
}

export type PartialConfig = {
	cycleSeconds: number?,
	binSize: number?,
	freezeSeconds: number?,
	maxBins: number?,
}

-- One pad unit: co-present friends grouped by the caller (else a singleton),
-- stamped with the EARLIEST member's pad-arrival time.
export type Unit = {
	keys: { Key },
	arrivedAt: number,
}

export type DispatchPlan = {
	bins: { { Key } }, -- launch these now, one ShiftSession each
	deferredBins: { { Key } }, -- beyond freeSlots: "ALL FLOORS RUNNING"
}

local DispatchCore = {}

--------------------------------------------------------------------------------
-- Configuration
--------------------------------------------------------------------------------

function DispatchCore.config(partial: PartialConfig?): Config
	local p: PartialConfig = partial or {}
	return {
		cycleSeconds = p.cycleSeconds or GameConstants.INTERMISSION_SECONDS,
		binSize = p.binSize or 4,
		freezeSeconds = p.freezeSeconds or 3,
		maxBins = p.maxBins or 5,
	}
end

local DEFAULT_CONFIG = DispatchCore.config()

--------------------------------------------------------------------------------
-- Clock (the caller owns the epoch; these are pure reads)
--------------------------------------------------------------------------------

-- Seconds until the next T=0. Range (0, cycleSeconds]: at the exact dispatch
-- instant the SAME epoch already reads the next cycle's full countdown — the
-- silent rollover. No event may ever mutate the epoch.
function DispatchCore.remaining(epoch: number, now: number, config: Config?): number
	local cfg = config or DEFAULT_CONFIG
	return cfg.cycleSeconds - (now - epoch) % cfg.cycleSeconds
end

-- True inside the final freezeSeconds (DOORS CLOSING): the caller defers late
-- ENTRY to the next cycle; stepping OFF still removes (excludeKeys).
function DispatchCore.inFreeze(epoch: number, now: number, config: Config?): boolean
	local cfg = config or DEFAULT_CONFIG
	return DispatchCore.remaining(epoch, now, cfg) <= cfg.freezeSeconds
end

--------------------------------------------------------------------------------
-- Snapshot filtering
--------------------------------------------------------------------------------

-- Removes excluded keys (AFK-marked, leavers inside the freeze window) from
-- the partition input. Units are rebuilt — never mutated — and a unit whose
-- every member is excluded is dropped entirely.
function DispatchCore.excludeKeys(units: { Unit }, excluded: { [Key]: boolean }): { Unit }
	local filtered: { Unit } = {}
	for _, unit in units do
		local keys: { Key } = {}
		for _, key in unit.keys do
			if excluded[key] ~= true then
				table.insert(keys, key)
			end
		end
		if #keys > 0 then
			table.insert(filtered, { keys = keys, arrivedAt = unit.arrivedAt })
		end
	end
	return filtered
end

--------------------------------------------------------------------------------
-- Partitioning
--------------------------------------------------------------------------------

type OrderedUnit = { unit: Unit, index: number }

-- Party-aware FIFO first-fit bin-packing. Units sort by earliest pad arrival
-- (ties keep input order — never random), oversized units split into
-- binSize + remainder chunks, and every chunk first-fits into the earliest
-- bin with room (a party <= binSize is never split across bins). The trailing
-- bin dispatches no matter how under-filled it is. Returned bins are fresh
-- tables — mutating the input afterward cannot change a computed plan.
function DispatchCore.partition(units: { Unit }, binSize: number): { { Key } }
	-- Stable FIFO order (table.sort alone is not stable).
	local ordered: { OrderedUnit } = {}
	for index, unit in units do
		table.insert(ordered, { unit = unit, index = index })
	end
	table.sort(ordered, function(a: OrderedUnit, b: OrderedUnit): boolean
		if a.unit.arrivedAt ~= b.unit.arrivedAt then
			return a.unit.arrivedAt < b.unit.arrivedAt
		end
		return a.index < b.index
	end)

	-- Oversized units split 4+remainder; everything else is one chunk.
	local chunks: { { Key } } = {}
	for _, entry in ordered do
		local keys = entry.unit.keys
		local cursor = 1
		while cursor <= #keys do
			local chunk: { Key } = {}
			for offset = cursor, math.min(cursor + binSize - 1, #keys) do
				table.insert(chunk, keys[offset])
			end
			table.insert(chunks, chunk)
			cursor += binSize
		end
	end

	-- First-fit: earliest bin with room, else open a new one.
	local bins: { { Key } } = {}
	for _, chunk in chunks do
		local placed = false
		for _, bin in bins do
			if #bin + #chunk <= binSize then
				for _, key in chunk do
					table.insert(bin, key)
				end
				placed = true
				break
			end
		end
		if not placed then
			table.insert(bins, chunk)
		end
	end
	return bins
end

-- The T=0 snapshot plan: partition every occupant, launch the first
-- `freeSlots` bins (clamped to the maxBins slot pool), defer ONLY the bins
-- beyond that — those occupants see "ALL FLOORS RUNNING" and roll into the
-- next cycle's snapshot. Dispatching never reads or writes the epoch.
function DispatchCore.planDispatch(occupants: { Unit }, freeSlots: number, config: Config?): DispatchPlan
	local cfg = config or DEFAULT_CONFIG
	local allBins = DispatchCore.partition(occupants, cfg.binSize)
	local slots = math.clamp(math.floor(freeSlots), 0, cfg.maxBins)

	local bins: { { Key } } = {}
	local deferredBins: { { Key } } = {}
	for index, bin in allBins do
		if index <= slots then
			table.insert(bins, bin)
		else
			table.insert(deferredBins, bin)
		end
	end
	return { bins = bins, deferredBins = deferredBins }
end

--------------------------------------------------------------------------------
-- Start-now vote
--------------------------------------------------------------------------------

-- Unanimous Start-now vote over the CURRENT pad occupants: true only when
-- there is at least one occupant and EVERY occupant has voted true. A passing
-- vote dispatches an extra bin immediately (caller checks the free slot) and
-- never moves the epoch. The caller MUST clear `votes` whenever a new key
-- enters the pad — unanimity among yesterday's occupants is not unanimity.
function DispatchCore.voteReady(votes: { [Key]: boolean }, occupantKeys: { Key }): boolean
	if #occupantKeys == 0 then
		return false
	end
	for _, key in occupantKeys do
		if votes[key] ~= true then
			return false
		end
	end
	return true
end

return table.freeze(DispatchCore)
