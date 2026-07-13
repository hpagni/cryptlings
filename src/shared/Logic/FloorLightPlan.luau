--!strict
-- Shared.Logic.FloorLightPlan — deterministic floor lighting plan (R6 Fix #1).
-- Decides, per generic room, whether it gets an overhead light, its color, and
-- whether it flickers. Guarantees >= 50% of generic rooms are overhead-lit as a
-- COUNT (not a probability) on every seed/scale. Pure: no Roblox APIs (no
-- Instance, no Color3, no Random) so it runs under Lune and is unit-pinned.
--
-- FloorGenService calls plan() with the per-room rolls it ALREADY drew from its
-- single seeded stream; this module adds NO randomness of its own (C1 — the
-- per-cell rng draw order is untouched; color is derived from existing rolls).

export type RoomLightKind = "warm" | "orange" | "cyan" -- overhead color variants
export type NightColor = "orange" | "purple" -- unlit-room night-light

export type RoomPlan = {
	lit: boolean, -- true => overhead ceiling fixture; false => night-light
	overheadColor: RoomLightKind?, -- present iff lit
	nightColor: NightColor?, -- present iff not lit
	flicker: boolean, -- overhead only; night-lights never flicker
}

export type FloorPlan = {
	rooms: { RoomPlan }, -- index 1..roomCount, generic-room order
	litCount: number, -- guaranteed >= ceil(roomCount * MIN_LIT_FRACTION)
}

export type RoomRoll = { light: number, flicker: number }

local FloorLightPlan = {}

FloorLightPlan.MIN_LIT_FRACTION = 0.50 -- HARD floor: >=50% overhead-lit, deterministic
FloorLightPlan.LIT_TARGET_FRACTION = 0.72 -- target above the floor at full density
FloorLightPlan.FLICKER_FRACTION = 0.5 -- share of lit rooms that flicker
FloorLightPlan.ORANGE_FRACTION = 0.20 -- share of lit rooms with warm-orange tint
FloorLightPlan.CYAN_FRACTION = 0.10 -- share of lit rooms with cool-cyan tint

local function round(x: number): number
	return math.floor(x + 0.5)
end

-- _seed: the floor seed (same value FloorGenService.Generate got). Accepted for
--   API symmetry and future use; the plan is fully determined by the rolls (which
--   already come from the seeded stream), so it is not consumed here.
-- roomCount: number of GENERIC rooms (excludes dock + vault) = 34 on a 6x6.
-- densityScale: ShiftService's 1/liveSessionCount (or 1). Used to shed lights
--   under load but CLAMPED so the 50% floor is always met.
-- rolls: the per-room rolls FloorGenService already drew, in generic-room order:
--   { { light: number, flicker: number } } where each number is in [0,1).
function FloorLightPlan.plan(
	_seed: number,
	roomCount: number,
	densityScale: number,
	rolls: { RoomRoll }
): FloorPlan
	-- 1) Hard floor.
	local minLit = math.ceil(roomCount * FloorLightPlan.MIN_LIT_FRACTION)

	-- 2) Effective lit fraction, density-scaled but clamped so the floor is always
	--    reachable. 1 session -> 0.72; 5 sessions (0.2) -> clamp(0.144,..) = 0.50.
	local effFrac = math.clamp(
		FloorLightPlan.LIT_TARGET_FRACTION * densityScale,
		FloorLightPlan.MIN_LIT_FRACTION,
		FloorLightPlan.LIT_TARGET_FRACTION
	)

	-- 3) Deterministic lit COUNT (never below the floor).
	local litCount = math.max(minLit, round(roomCount * effFrac))
	litCount = math.min(litCount, roomCount)

	-- 4) Choose WHICH rooms are lit: rank generic rooms by their existing light
	--    roll (stable: key = light value, tiebreak = original index). The litCount
	--    rooms with the LOWEST light roll are lit; the rest get night-lights. Reuses
	--    the already-drawn roll (C1), fully deterministic for a given seed.
	local order: { number } = {}
	for i = 1, roomCount do
		order[i] = i
	end
	table.sort(order, function(a: number, b: number): boolean
		local la, lb = rolls[a].light, rolls[b].light
		if la == lb then
			return a < b
		end
		return la < lb
	end)

	-- 5) Overhead color by rank position WITHIN the lit set so counts are exact:
	--    first ORANGE_FRACTION -> orange, next CYAN_FRACTION -> cyan, rest warm.
	local orangeCount = round(litCount * FloorLightPlan.ORANGE_FRACTION)
	local cyanCount = round(litCount * FloorLightPlan.CYAN_FRACTION)

	local rooms: { RoomPlan } = {}
	for i = 1, roomCount do
		rooms[i] = {
			lit = false,
			overheadColor = nil,
			nightColor = nil,
			flicker = false,
		}
	end

	for litRank = 1, litCount do
		local roomIndex = order[litRank]
		local overheadColor: RoomLightKind
		if litRank <= orangeCount then
			overheadColor = "orange"
		elseif litRank <= orangeCount + cyanCount then
			overheadColor = "cyan"
		else
			overheadColor = "warm"
		end
		rooms[roomIndex] = {
			lit = true,
			overheadColor = overheadColor,
			nightColor = nil,
			-- 6) Flicker from the existing flicker roll (same 50% as today); the
			--    SERVICE applies the new 0.5-2 Hz frequency.
			flicker = rolls[roomIndex].flicker < FloorLightPlan.FLICKER_FRACTION,
		}
	end

	-- 7) Night color for each unlit room, from the EXISTING flicker roll (~50/50).
	for i = 1, roomCount do
		if not rooms[i].lit then
			local nightColor: NightColor = if rolls[i].flicker < 0.5 then "orange" else "purple"
			rooms[i] = {
				lit = false,
				overheadColor = nil,
				nightColor = nightColor,
				flicker = false,
			}
		end
	end

	return { rooms = rooms, litCount = litCount }
end

return FloorLightPlan
