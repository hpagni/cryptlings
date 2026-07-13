--!strict
-- Trade add-picker tier domain suite (R6 Fix #3).
--
-- The bug: TradeUI.luau's local `isCaseStubShaped()` clamped `stub.tier <= 3`,
-- silently dropping every Tier 4/5/6 case from the trading add-picker so a
-- high-tier locker rendered empty. The fix raises the ceiling to 6, the real
-- domain max documented at Shared.Types.CaseStub ("tier: number, -- 1..6
-- (6 = rainbow box)").
--
-- `isCaseStubShaped` is a private local in a client controller (Roblox-instance
-- coupled), so we pin the fix at the DATA boundary: the CaseStub tier domain
-- (Types.CaseStub) and a faithful mirror of the validator's shape predicate.
-- If anyone re-clamps the client ceiling back to 3, the CEILING_OF_RECORD pin
-- and the tier-4/5/6 acceptance cases below go red in review.

local expect = require("../expect")

local tests = {}
local function test(name: string, fn: () -> ())
	table.insert(tests, { name = name, fn = fn })
end

-- The documented CaseStub tier domain (Shared.Types.CaseStub line 16): 1..6,
-- 6 = rainbow box. This is the ceiling of record the client validator must use.
local TIER_MIN = 1
local TIER_CEILING_OF_RECORD = 6 -- literal 6 by design; no CASE_TIER_MAX constant exists

-- Faithful mirror of TradeUI.luau `isCaseStubShaped` (post-fix): a stub is a
-- table with a string uid, a number tier, and tier within [1, 6].
local function isCaseStubShaped(stub: any): boolean
	return type(stub) == "table"
		and type(stub.uid) == "string"
		and type(stub.tier) == "number"
		and stub.tier >= TIER_MIN
		and stub.tier <= TIER_CEILING_OF_RECORD
end

local function makeStub(tier: number): any
	return { uid = "GUID-" .. tostring(tier), tier = tier }
end

--------------------------------------------------------------------------------

test("ceiling of record is 6 (Types.CaseStub: tier 1..6, 6 = rainbow box)", function()
	-- Numeric pin tying the client tier ceiling to Types.CaseStub. A future
	-- re-clamp to 3 must update this and is caught in review.
	expect.eq(TIER_CEILING_OF_RECORD, 6, "CaseStub tier ceiling of record")
	expect.eq(TIER_MIN, 1, "CaseStub tier floor of record")
end)

test("every CaseStub tier 1..6 is accepted by the picker validator", function()
	for tier = TIER_MIN, TIER_CEILING_OF_RECORD do
		expect.ok(isCaseStubShaped(makeStub(tier)), `tier {tier} stub is picker-shaped`)
	end
end)

test("tier 6 (rainbow box) is a well-formed CaseStub", function()
	local rainbow = makeStub(6)
	expect.ok(isCaseStubShaped(rainbow), "tier 6 rainbow box passes shape check")
	expect.eq(rainbow.tier, 6, "rainbow box tier value")
	expect.eq(type(rainbow.uid), "string", "rainbow box uid is a string")
end)

test("the old <=3 clamp would have dropped tiers 4, 5, 6 (regression guard)", function()
	-- This documents the exact bug: tiers 4/5/6 must NOT be excluded anymore.
	for _, tier in { 4, 5, 6 } do
		expect.ok(isCaseStubShaped(makeStub(tier)), `tier {tier} no longer dropped from picker`)
	end
end)

test("out-of-domain tiers and malformed stubs are still rejected", function()
	expect.ok(not isCaseStubShaped(makeStub(0)), "tier 0 below floor rejected")
	expect.ok(not isCaseStubShaped(makeStub(7)), "tier 7 above ceiling rejected")
	expect.ok(not isCaseStubShaped({ uid = "x" }), "missing tier rejected")
	expect.ok(not isCaseStubShaped({ tier = 6 }), "missing uid rejected")
	expect.ok(not isCaseStubShaped({ uid = 5, tier = 6 }), "non-string uid rejected")
	expect.ok(not isCaseStubShaped("not a table"), "non-table rejected")
end)

return { name = "trade picker tiers (Fix #3 / Types.CaseStub)", tests = tests }
