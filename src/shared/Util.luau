--!strict
-- CRYPTLINGS: NIGHT SHIFT — shared utility library (Stage 0).
-- Pure Luau: requires no Roblox globals (lune-safe). Keep it that way.

local SECONDS_PER_DAY = 86400

local Util = {}

-- Deep-copies a table (values only; no metatables, per ProfileService data rules).
function Util.DeepCopy<T>(value: T): T
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for key, inner in value :: any do
		copy[key] = Util.DeepCopy(inner)
	end
	return copy :: any
end

function Util.ShallowCopy<K, V>(dict: { [K]: V }): { [K]: V }
	return table.clone(dict)
end

-- Number of entries in a dictionary (not just the array part).
function Util.Count(dict: { [any]: any }): number
	local count = 0
	for _ in dict do
		count += 1
	end
	return count
end

function Util.Keys<K, V>(dict: { [K]: V }): { K }
	local keys = {}
	for key in dict do
		table.insert(keys, key)
	end
	return keys
end

function Util.Clamp01(x: number): number
	return math.clamp(x, 0, 1)
end

function Util.Lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

-- Unix day index (00:00 UTC boundary) — the locker daily-reset clock (§G).
function Util.UnixDay(now: number?): number
	return math.floor((now or os.time()) / SECONDS_PER_DAY)
end

-- Unix time of the next unix-day boundary after `now`.
function Util.NextDayBoundary(now: number?): number
	return (Util.UnixDay(now) + 1) * SECONDS_PER_DAY
end

-- Next boundary STRICTLY after `now` on the fixed grid anchor + k * step
-- (k integer; the toy-line season grid, §G TOYLINE_EPOCH_ANCHOR). Deterministic
-- across servers and pre-anchor safe: any now < anchor returns the anchor
-- itself; now exactly on a boundary returns the following one.
function Util.NextGridBoundary(anchor: number, step: number, now: number?): number
	assert(step > 0, "Util.NextGridBoundary: step must be > 0")
	local t = now or os.time()
	local cyclesDone = math.floor((t - anchor) / step)
	return anchor + (cyclesDone + 1) * step
end

-- Picks an index from an array of positive integer weights given roll01 in [0, 1).
-- Pure helper backing weighted rarity rolls; deterministic for a given roll01.
function Util.WeightedIndex(weights: { number }, roll01: number): number
	local total = 0
	for _, weight in weights do
		total += weight
	end
	assert(total > 0, "Util.WeightedIndex: weights must sum to > 0")
	local threshold = roll01 * total
	local cumulative = 0
	for index, weight in weights do
		cumulative += weight
		if threshold < cumulative then
			return index
		end
	end
	return #weights -- roll01 at the very top edge
end

-- Appends to an array treated as a ring buffer, dropping the oldest past maxSize.
function Util.RingAppend<T>(buffer: { T }, value: T, maxSize: number)
	table.insert(buffer, value)
	while #buffer > maxSize do
		table.remove(buffer, 1)
	end
end

return table.freeze(Util)
