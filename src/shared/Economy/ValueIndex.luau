--!strict
-- CRYPTLINGS: NIGHT SHIFT — Trade Value Index (Stage 4, SOP §3.1 ④, §3.3, §8.1).
-- Single source of truth for what a duplicate Cryptling or a sealed case is
-- "worth" when two players trade at the hub swap meet. TradeService (server
-- authority) computes both sides' values with this module and stamps
-- TradeState.valueWarning; TradeUI only displays what the server computed —
-- the client NEVER derives its own verdict (§8.1 scam mitigations).
--
-- Pure Luau: requires no Roblox globals, so lune can run headless scratch
-- checks and TestEZ specs can exercise it without a DataModel (§J).
--
-- MD TUNING (§4.4): every threshold and value lives in the named constants
-- below. Max one economy change per week, via a committed edit to this file —
-- never hand-edited live. The season retro reviews trade-value inflation
-- against these numbers at each 6-week boundary.

local RarityTable = require("../Config/RarityTable")

--------------------------------------------------------------------------------
-- TUNING CONSTANTS (the §4.4 dials — change values here, nowhere else)
--------------------------------------------------------------------------------

-- Relative worth of an unboxed, tradeable Cryptling by rarity. Anchored to
-- pull odds at the Tier 2 baseline (50/30/15/4.5/0.5%): each step up is
-- roughly as scarce as the value multiple implies, with Godly priced at a
-- deliberate premium (1-of-12 roster jackpot, the social flex item).
local BASE_VALUES: { [string]: number } = table.freeze({
	Common = 1,
	Uncommon = 3,
	Rare = 10,
	Epic = 40,
	Legendary = 400, -- inherited the old Godly slot and rates, so the old value
	Godly = 1200, -- 10x rarer than Legendary
	Mythical = 5000, -- flat 1-in-100,000
})

-- Worth of a SEALED case by tier. Derivation (documented per spec):
-- expected open value at each tier's disclosed odds (RarityTable.TIER_WEIGHTS),
--   EV(tier) = sum over rarities of pct * BASE_VALUES[rarity]
--   EV(T1) = 0.65*1 + 0.27*3 + 0.07*10 + 0.009*40 + 0.001*400 =  2.92
--   EV(T2) = 0.50*1 + 0.30*3 + 0.15*10 + 0.045*40 + 0.005*400 =  6.70
--   EV(T3) = 0.30*1 + 0.35*3 + 0.25*10 + 0.085*40 + 0.015*400 = 13.25
-- Sealed cases trade BELOW expected value: the daily open cap (3 free/day)
-- rate-limits realization, and the holder bears all the variance. We apply a
-- roughly-two-thirds sealed discount (2/2.92 = 0.685, 4/6.70 = 0.597,
-- 9/13.25 = 0.679) and round to friendly integers, which keeps the tier
-- ratios ≈ the EV ratios (2 : 4 : 9 vs 2.92 : 6.70 : 13.25):
local CASE_VALUES: { [number]: number } = table.freeze({
	[1] = 2,
	[2] = 4,
	[3] = 9,
})

-- A trade is "lopsided" (server flags valueWarning, UI shows the big red
-- banner on both confirm screens) when one side is worth LOPSIDED_RATIO times
-- the other AND the bigger side is worth at least LOPSIDED_MIN_TOP_VALUE.
-- The floor exists so trivial trades never nag (3 Commons for 1 Uncommon is
-- ratio 1.0; even 2 Commons for 1 Common — ratio 2x but max value 2 — stays
-- quiet). Godly-for-Common (400 vs 1) trips both gates hard.
local LOPSIDED_RATIO = 3
local LOPSIDED_MIN_TOP_VALUE = 10

--------------------------------------------------------------------------------
-- Types
--------------------------------------------------------------------------------

-- One side of a trade, as TradeService resolves it before valuation.
-- caseStubsOrTiers may hold full CaseStubs ({uid, tier, ...}) or bare tier
-- numbers — TradeService resolves offered caseUids to stubs from the profile;
-- specs and the UI preview path can pass plain tiers.
export type Offer = {
	caseStubsOrTiers: { CaseLike }?,
	cryptlings: { [string]: number }?, -- cryptlingId -> count (duplicates only)
}

export type CaseLike = number | { tier: number }

export type Comparison = {
	ratio: number, -- max(side) / min(side); math.huge for something-for-nothing
	warn: boolean, -- == IsLopsided(a, b); copy into TradeState.valueWarning
}

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

local ValueIndex = {}

ValueIndex.BASE_VALUES = BASE_VALUES
ValueIndex.CASE_VALUES = CASE_VALUES
ValueIndex.LOPSIDED_RATIO = LOPSIDED_RATIO
ValueIndex.LOPSIDED_MIN_TOP_VALUE = LOPSIDED_MIN_TOP_VALUE

-- False for misprint_trophy (tradeable = false), any notInPool entry, and any
-- unknown id (fail closed — TradeService rejects these before they ever reach
-- an offer; §8.1).
function ValueIndex.IsTradeable(id: string): boolean
	local def = RarityTable.GetCryptling(id)
	if def == nil then
		return false
	end
	if def.notInPool == true or def.tradeable == false then
		return false
	end
	return true
end

-- Value of a single item. kind "cryptling" takes a roster id; kind "case"
-- takes a tier (1|2|3). Untradeable/unknown cryptlings and unknown tiers are
-- worth 0 — they contribute nothing to an offer and cannot mask a lopsided
-- trade.
function ValueIndex.ItemValue(kind: "cryptling" | "case", idOrTier: string | number): number
	if kind == "cryptling" then
		assert(type(idOrTier) == "string", "ValueIndex.ItemValue: cryptling id must be a string")
		if not ValueIndex.IsTradeable(idOrTier) then
			return 0
		end
		local def = RarityTable.GetCryptling(idOrTier)
		return BASE_VALUES[def.rarity] or 0
	elseif kind == "case" then
		assert(type(idOrTier) == "number", "ValueIndex.ItemValue: case tier must be a number")
		return CASE_VALUES[idOrTier] or 0
	end
	error(`ValueIndex.ItemValue: unknown kind {tostring(kind)}`)
end

-- Total value of one side's offer. Negative cryptling counts are clamped to 0
-- (counts are server-validated upstream; valuation never goes negative).
function ValueIndex.OfferValue(offer: Offer): number
	local total = 0
	if offer.caseStubsOrTiers ~= nil then
		for _, entry in offer.caseStubsOrTiers do
			local tier = if type(entry) == "number" then entry else entry.tier
			total += ValueIndex.ItemValue("case", tier)
		end
	end
	if offer.cryptlings ~= nil then
		for id, count in offer.cryptlings do
			total += ValueIndex.ItemValue("cryptling", id) * math.max(0, count)
		end
	end
	return total
end

-- True when the trade deserves a value warning: one side is worth
-- LOPSIDED_RATIO x the other AND the bigger side is at least
-- LOPSIDED_MIN_TOP_VALUE (trivial trades are ignored). A non-empty side
-- against a zero side is always lopsided once it clears the floor.
function ValueIndex.IsLopsided(valueA: number, valueB: number): boolean
	local high = math.max(valueA, valueB)
	local low = math.min(valueA, valueB)
	if high < LOPSIDED_MIN_TOP_VALUE then
		return false
	end
	if low <= 0 then
		return true
	end
	return high / low >= LOPSIDED_RATIO
end

-- Convenience for TradeService/TradeUI: ratio between the sides plus the
-- warning verdict in one call. ratio is 1 for two empty sides and math.huge
-- for something-for-nothing.
function ValueIndex.Compare(a: number, b: number): Comparison
	local high = math.max(a, b)
	local low = math.min(a, b)
	local ratio
	if low > 0 then
		ratio = high / low
	elseif high > 0 then
		ratio = math.huge
	else
		ratio = 1
	end
	return {
		ratio = ratio,
		warn = ValueIndex.IsLopsided(a, b),
	}
end

-- MD tuning aid (§4.4): exact expected open value of a tier at its disclosed
-- odds, computed live from RarityTable so the CASE_VALUES derivation above is
-- verifiable in tests whenever either table changes.
function ValueIndex.ExpectedOpenValue(tier: number): number
	local weights = RarityTable.GetWeights(tier)
	local total = 0
	for rarity, weight in weights do
		total += (BASE_VALUES[rarity] or 0) * weight
	end
	return total / RarityTable.WEIGHT_TOTAL
end

return table.freeze(ValueIndex)
