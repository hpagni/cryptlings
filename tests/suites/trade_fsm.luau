--!strict
-- Trading state-machine suite (SOP §3.1 ④, §3.3 confirm-twice + value warnings,
-- §8.2 "no dupe-prone trade code" pre-launch blocker). Exercises the SHIPPED
-- Shared.Logic.TradeFlow — the exact module TradeService's remote handlers and
-- atomic execute delegate to — plus the ValueIndex thresholds it warns with.

local GameConstants = require("../../src/shared/Config/GameConstants")
local TradeFlow = require("../../src/shared/Logic/TradeFlow")
local ValueIndex = require("../../src/shared/Economy/ValueIndex")
local expect = require("../expect")

local tests = {}
local function test(name: string, fn: () -> ())
	table.insert(tests, { name = name, fn = fn })
end

local DELAY = GameConstants.TRADE_CONFIRM_STAGE2_DELAY_SECONDS -- 3 (§3.3)

--------------------------------------------------------------------------------
-- Fixtures (plain tables shaped like Types.ProfileData / the session FSM slice)
--------------------------------------------------------------------------------

local function caseStub(uid: string, tier: number): any
	return { uid = uid, tier = tier, lineId = "line1", acquiredAt = 1000, source = "run" }
end

local function newProfile(cases: { any }?, collection: { [string]: number }?): any
	return {
		collection = collection or {},
		locker = { cases = cases or {}, freeOpensUsed = 0, lastResetDay = 0, extraOpenCredits = 0 },
		tradeHistory = {},
	}
end

local function newFlow(idA: number, idB: number): any
	return {
		userIds = { idA, idB },
		offers = TradeFlow.NewOffers(idA, idB),
		confirmReadyClock = nil,
		stage2AtUnix = nil,
	}
end

-- Minimal PlayerDataService stand-in: Update(playerLike, fn) runs fn on that
-- fixture's profile (the only surface TradeFlow.DoSwap consumes).
local function newWorld(): (any, any, any, { [number]: any })
	local profiles: { [number]: any } = {}
	local playerA = { UserId = 1, Name = "Aud" }
	local playerB = { UserId = 2, Name = "Bex" }
	local dataService = {
		Update = function(playerLike: any, fn: (any) -> ()): boolean
			local data = profiles[playerLike.UserId]
			if data == nil then
				return false
			end
			fn(data)
			return true
		end,
	}
	return dataService, playerA, playerB, profiles
end

local function offer(caseUids: { string }, cryptlings: { [string]: number }): any
	return { caseUids = caseUids, cryptlings = cryptlings, confirmStage = 0 }
end

-- Total item census across both profiles — the conservation invariant: a trade
-- must move items, never mint or burn them.
local function census(profiles: { [number]: any }): ({ [string]: number }, { [string]: number })
	local uids: { [string]: number } = {}
	local counts: { [string]: number } = {}
	for _, data in profiles do
		for _, stub in data.locker.cases do
			uids[stub.uid] = (uids[stub.uid] or 0) + 1
		end
		for id, count in data.collection do
			counts[id] = (counts[id] or 0) + count
		end
	end
	return uids, counts
end

--------------------------------------------------------------------------------
-- SanitizeOffer
--------------------------------------------------------------------------------

test("SanitizeOffer accepts a valid offer and normalizes it", function()
	local caseUids, cryptlings, err = TradeFlow.SanitizeOffer({
		caseUids = { "uid-1", "uid-2" },
		cryptlings = { smudge = 2, prototype_zero = 1 },
	})
	expect.eq(err, nil, "no error")
	expect.deepEq(caseUids, { "uid-1", "uid-2" }, "case uids preserved")
	expect.deepEq(cryptlings, { smudge = 2, prototype_zero = 1 }, "cryptling counts preserved")

	local emptyUids, emptyCrypts, emptyErr = TradeFlow.SanitizeOffer({})
	expect.eq(emptyErr, nil, "empty offer sanitizes")
	expect.eq(#(emptyUids :: { string }), 0, "no uids")
	expect.eq(next(emptyCrypts :: { [string]: number }), nil, "no cryptlings")
end)

test("SanitizeOffer rejects dupes, bad counts, unknown ids, and untradeables", function()
	local function errOf(raw: any): string?
		local _, _, err = TradeFlow.SanitizeOffer(raw)
		return err
	end
	expect.eq(errOf(nil), "BAD_OFFER", "non-table payload")
	expect.eq(errOf({ caseUids = { "u1", "u1" } }), "BAD_OFFER", "duplicate uid = double-spend attempt")
	expect.eq(errOf({ caseUids = { "" } }), "BAD_OFFER", "empty uid")
	expect.eq(errOf({ caseUids = { string.rep("x", 65) } }), "BAD_OFFER", "oversized uid")
	expect.eq(errOf({ cryptlings = { smudge = 0 } }), "BAD_OFFER", "zero count")
	expect.eq(errOf({ cryptlings = { smudge = -1 } }), "BAD_OFFER", "negative count")
	expect.eq(errOf({ cryptlings = { smudge = 1.5 } }), "BAD_OFFER", "fractional count")
	expect.eq(errOf({ cryptlings = { smudge = 0 / 0 } }), "BAD_OFFER", "NaN count")
	expect.eq(errOf({ cryptlings = { smudge = 100 } }), "BAD_OFFER", "count above per-kind cap")
	expect.eq(errOf({ cryptlings = { not_a_cryptling = 1 } }), "BAD_OFFER", "unknown roster id")
	expect.eq(errOf({ cryptlings = { misprint_trophy = 1 } }), "NOT_TRADEABLE", "starter-pack trophy (§4.2)")

	local tooMany = {}
	for index = 1, GameConstants.TRADE_MAX_OFFER_CASES + 1 do
		table.insert(tooMany, `uid-{index}`)
	end
	expect.eq(errOf({ caseUids = tooMany }), "OFFER_TOO_LARGE", "21 cases")
end)

--------------------------------------------------------------------------------
-- Confirm-twice FSM (§3.3)
--------------------------------------------------------------------------------

test("confirm-twice happy path: stage 1 both, 3s server gate, then stage 2 both", function()
	local flow = newFlow(1, 2)
	TradeFlow.ApplySetOffer(flow, 1, { "u1" }, {})
	TradeFlow.ApplySetOffer(flow, 2, {}, { smudge = 1 })

	local r1 = TradeFlow.ApplyConfirm(flow, 1, 2, 1, 100, 5000)
	expect.ok(r1.ok and r1.changed and not r1.executeNow, "A stage 1 accepted")
	expect.eq(flow.confirmReadyClock, nil, "no ready clock until BOTH at stage 1")

	local r2 = TradeFlow.ApplyConfirm(flow, 2, 1, 1, 101, 5001)
	expect.ok(r2.ok and r2.changed, "B stage 1 accepted")
	expect.eq(flow.confirmReadyClock, 101, "ready clock stamped when both reach stage 1")
	expect.eq(flow.stage2AtUnix, 5001 + DELAY, "client-facing stage-2 unlock time")

	local early = TradeFlow.ApplyConfirm(flow, 1, 2, 2, 101 + DELAY - 0.1, 5004)
	expect.eq(early.ok, false, "stage 2 before the gate rejected")
	expect.eq(early.err, "TOO_SOON", "TOO_SOON before the server-timed 3s")
	expect.eq(flow.offers[1].confirmStage, 1, "stage unchanged after TOO_SOON")

	local r3 = TradeFlow.ApplyConfirm(flow, 1, 2, 2, 101 + DELAY, 5004)
	expect.ok(r3.ok and r3.changed and not r3.executeNow, "A stage 2 at exactly +3s; waits for B")

	local r4 = TradeFlow.ApplyConfirm(flow, 2, 1, 2, 101 + DELAY + 1, 5005)
	expect.ok(r4.ok and r4.changed, "B stage 2 accepted")
	expect.eq(r4.executeNow, true, "both at stage 2 => execute exactly now")
end)

test("stage ordering guards: EMPTY_TRADE, CONFIRM_STAGE1_FIRST, NOT_READY", function()
	local flow = newFlow(1, 2)
	local empty = TradeFlow.ApplyConfirm(flow, 1, 2, 1, 0, 0)
	expect.eq(empty.err, "EMPTY_TRADE", "nothing on either side cannot be confirmed")

	TradeFlow.ApplySetOffer(flow, 1, { "u1" }, {})
	local skip = TradeFlow.ApplyConfirm(flow, 1, 2, 2, 0, 0)
	expect.eq(skip.err, "CONFIRM_STAGE1_FIRST", "stage 2 without own stage 1")

	expect.ok(TradeFlow.ApplyConfirm(flow, 1, 2, 1, 0, 0).ok, "A stage 1")
	local lone = TradeFlow.ApplyConfirm(flow, 1, 2, 2, 1000, 1000)
	expect.eq(lone.err, "NOT_READY", "stage 2 while partner still at stage 0")
end)

test("re-pressing confirm is idempotent (no dupe on double-accept)", function()
	local flow = newFlow(1, 2)
	TradeFlow.ApplySetOffer(flow, 1, { "u1" }, {})
	TradeFlow.ApplyConfirm(flow, 1, 2, 1, 0, 0)

	local again = TradeFlow.ApplyConfirm(flow, 1, 2, 1, 1, 1)
	expect.ok(again.ok and not again.changed, "stage-1 re-press is a silent ok")

	TradeFlow.ApplyConfirm(flow, 2, 1, 1, 2, 2)
	TradeFlow.ApplyConfirm(flow, 1, 2, 2, 2 + DELAY, 10)
	local repress = TradeFlow.ApplyConfirm(flow, 1, 2, 2, 3 + DELAY, 11)
	expect.ok(repress.ok and not repress.changed and not repress.executeNow, "stage-2 re-press never re-executes")

	-- Partner completes: exactly ONE press in the whole exchange may executeNow.
	local final = TradeFlow.ApplyConfirm(flow, 2, 1, 2, 3 + DELAY, 11)
	expect.eq(final.executeNow, true, "partner's stage 2 executes")
	local afterDone = TradeFlow.ApplyConfirm(flow, 2, 1, 2, 4 + DELAY, 12)
	expect.ok(afterDone.ok and not afterDone.executeNow, "double-accept after completion is inert")
end)

test("ANY offer mutation after confirms resets BOTH stages and the clocks", function()
	local flow = newFlow(1, 2)
	TradeFlow.ApplySetOffer(flow, 1, { "u1" }, {})
	TradeFlow.ApplySetOffer(flow, 2, { "u2" }, {})
	TradeFlow.ApplyConfirm(flow, 1, 2, 1, 0, 0)
	TradeFlow.ApplyConfirm(flow, 2, 1, 1, 1, 1)
	TradeFlow.ApplyConfirm(flow, 1, 2, 2, 1 + DELAY, 9) -- A is fully committed
	expect.eq(flow.offers[1].confirmStage, 2, "A at stage 2")

	-- B swaps the item under A's nose — the §3.3 bait-and-switch defense.
	TradeFlow.ApplySetOffer(flow, 2, { "u3" }, {})
	expect.eq(flow.offers[1].confirmStage, 0, "A's confirm fully reset")
	expect.eq(flow.offers[2].confirmStage, 0, "B's confirm fully reset")
	expect.eq(flow.confirmReadyClock, nil, "ready clock cleared")
	expect.eq(flow.stage2AtUnix, nil, "stage-2 unlock cleared")

	local tooSoon = TradeFlow.ApplyConfirm(flow, 1, 2, 2, 100, 100)
	expect.eq(tooSoon.err, "CONFIRM_STAGE1_FIRST", "must restart the confirm-twice flow")
end)

--------------------------------------------------------------------------------
-- Atomic swap (§8.2)
--------------------------------------------------------------------------------

test("DoSwap moves items exactly once and conserves the item census", function()
	local dataService, playerA, playerB, profiles = newWorld()
	profiles[1] = newProfile({ caseStub("u1", 2), caseStub("u2", 3) }, { smudge = 2 })
	profiles[2] = newProfile({ caseStub("u3", 1) }, { prototype_zero = 1 })

	local beforeUids, beforeCounts = census(profiles)
	local offerA = offer({ "u1" }, { smudge = 1 })
	local offerB = offer({ "u3" }, { prototype_zero = 1 })

	local outcome = TradeFlow.DoSwap(dataService, "trade-1", playerA, playerB, offerA, offerB)
	expect.eq(outcome.ok, true, "swap committed")
	expect.eq(#(outcome.takenA :: { any }), 1, "one case taken from A")

	-- Ownership moved...
	local ownsA: { [string]: boolean } = {}
	for _, stub in profiles[1].locker.cases do
		ownsA[stub.uid] = true
	end
	expect.ok(ownsA["u3"] == true and ownsA["u2"] == true and ownsA["u1"] == nil, "A now holds u2+u3, not u1")
	expect.eq(profiles[2].locker.cases[1].uid, "u1", "B now holds u1")
	expect.eq(profiles[1].collection.smudge, 1, "A kept 1 smudge")
	expect.eq(profiles[1].collection.prototype_zero, 1, "A received the godly")
	expect.eq(profiles[2].collection.smudge, 1, "B received 1 smudge")
	expect.eq(profiles[2].collection.prototype_zero, nil, "B's godly count cleaned to nil at 0")

	-- ...and NOTHING was minted or burned (the §8.2 invariant).
	local afterUids, afterCounts = census(profiles)
	expect.deepEq(afterUids, beforeUids, "case uid census conserved")
	expect.deepEq(afterCounts, beforeCounts, "cryptling count census conserved")
	for uid, count in afterUids do
		expect.eq(count, 1, `case {uid} exists exactly once`)
	end

	-- Both tradeHistory rings got exactly one mirrored record.
	expect.eq(#profiles[1].tradeHistory, 1, "A history appended once")
	expect.eq(#profiles[2].tradeHistory, 1, "B history appended once")
	expect.eq(profiles[1].tradeHistory[1].partnerId, 2, "A's record names B")
	expect.deepEq(profiles[1].tradeHistory[1].gave.cases, { "u1" }, "A's record gave u1")
	expect.deepEq(profiles[2].tradeHistory[1].got.cases, { "u1" }, "B's record got u1")
end)

test("replaying the same accepted offers cannot dupe (second DoSwap is a no-op)", function()
	local dataService, playerA, playerB, profiles = newWorld()
	profiles[1] = newProfile({ caseStub("u1", 2) }, {})
	profiles[2] = newProfile({}, { wonk = 1 })

	local offerA = offer({ "u1" }, {})
	local offerB = offer({}, { wonk = 1 })
	expect.eq(TradeFlow.DoSwap(dataService, "t", playerA, playerB, offerA, offerB).ok, true, "first swap lands")

	local beforeUids, beforeCounts = census(profiles)
	local replay = TradeFlow.DoSwap(dataService, "t", playerA, playerB, offerA, offerB)
	expect.eq(replay.ok, false, "replay rejected")
	expect.eq(replay.err, "ITEMS_CHANGED", "revalidation inside the write lock catches it")
	local afterUids, afterCounts = census(profiles)
	expect.deepEq(afterUids, beforeUids, "replay minted no cases")
	expect.deepEq(afterCounts, beforeCounts, "replay minted no cryptlings")
	expect.eq(#profiles[2].tradeHistory, 1, "no extra history records")
end)

test("half-failure restores the first taker's items untouched", function()
	local dataService, playerA, playerB, profiles = newWorld()
	profiles[1] = newProfile({ caseStub("u1", 2) }, { smudge = 1 })
	profiles[2] = newProfile({}, {}) -- B no longer owns what they offered

	local outcome =
		TradeFlow.DoSwap(dataService, "t", playerA, playerB, offer({ "u1" }, { smudge = 1 }), offer({ "u9" }, {}))
	expect.eq(outcome.ok, false, "swap aborted")
	expect.eq(outcome.err, "ITEMS_CHANGED", "B's vanished item detected")
	expect.eq(profiles[1].locker.cases[1].uid, "u1", "A's case restored")
	expect.eq(profiles[1].collection.smudge, 1, "A's cryptling restored")
	expect.eq(#profiles[1].tradeHistory, 0, "no history written on a failed swap")
end)

test("TakeOfferFromData: validate-all-then-mutate (any miss leaves data untouched)", function()
	local data = newProfile({ caseStub("u1", 2) }, { smudge = 1 })

	expect.eq(TradeFlow.TakeOfferFromData(data, { "u1", "u1" }, {}), nil, "duplicate uid rejected")
	expect.eq(TradeFlow.TakeOfferFromData(data, { "u1" }, { smudge = 2 }), nil, "insufficient count rejected")
	expect.eq(TradeFlow.TakeOfferFromData(data, { "u1" }, { misprint_trophy = 1 }), nil, "untradeable rejected")
	expect.eq(#data.locker.cases, 1, "case still owned after every rejection")
	expect.eq(data.collection.smudge, 1, "collection untouched after every rejection")

	local taken = TradeFlow.TakeOfferFromData(data, { "u1" }, { smudge = 1 })
	expect.eq(#(taken :: { any }), 1, "valid take returns the stub")
	expect.eq(#data.locker.cases, 0, "case removed")
	expect.eq(data.collection.smudge, nil, "count decremented to nil")
end)

test("GrantToData caps tradeHistory at the 30-entry ring", function()
	local data = newProfile({}, {})
	for index = 1, GameConstants.TRADE_HISTORY_MAX + 5 do
		TradeFlow.GrantToData(data, {}, {}, {
			tradeId = `t-{index}`,
			partnerId = 2,
			gave = { cases = {}, cryptlings = {} },
			got = { cases = {}, cryptlings = {} },
			at = index,
		})
	end
	expect.eq(#data.tradeHistory, GameConstants.TRADE_HISTORY_MAX, "ring capped")
	expect.eq(data.tradeHistory[1].tradeId, "t-6", "oldest entries dropped")
	expect.eq(data.tradeHistory[GameConstants.TRADE_HISTORY_MAX].tradeId, "t-35", "newest kept")
end)

--------------------------------------------------------------------------------
-- Value-warning thresholds (§3.3)
--------------------------------------------------------------------------------

test("ValueIndex thresholds: 3x ratio with a 10-value floor", function()
	expect.eq(ValueIndex.LOPSIDED_RATIO, 3, "ratio dial of record")
	expect.eq(ValueIndex.LOPSIDED_MIN_TOP_VALUE, 10, "floor dial of record")

	expect.eq(ValueIndex.IsLopsided(30, 10), true, "exactly 3x at the floor warns")
	expect.eq(ValueIndex.IsLopsided(29, 10), false, "2.9x stays quiet")
	expect.eq(ValueIndex.IsLopsided(10, 0), true, "something-for-nothing warns once over the floor")
	expect.eq(ValueIndex.IsLopsided(9, 0), false, "trivial something-for-nothing stays quiet")
	expect.eq(ValueIndex.IsLopsided(9, 3), false, "3x under the floor stays quiet")
	expect.eq(ValueIndex.IsLopsided(0, 0), false, "two empty sides stay quiet")
	expect.eq(ValueIndex.IsLopsided(10, 30), true, "warning is symmetric")
end)

test("offer valuation matches the tuning tables (cases 2/4/9, godly 400)", function()
	expect.eq(ValueIndex.ItemValue("case", 1), 2, "tier 1 sealed case")
	expect.eq(ValueIndex.ItemValue("case", 2), 4, "tier 2 sealed case")
	expect.eq(ValueIndex.ItemValue("case", 3), 9, "tier 3 sealed case")
	expect.eq(ValueIndex.ItemValue("cryptling", "smudge"), 1, "common")
	expect.eq(ValueIndex.ItemValue("cryptling", "wonk"), 3, "uncommon")
	expect.eq(ValueIndex.ItemValue("cryptling", "sploot"), 10, "rare")
	expect.eq(ValueIndex.ItemValue("cryptling", "inkblot"), 40, "epic")
	expect.eq(ValueIndex.ItemValue("cryptling", "prototype_zero"), 400, "godly")
	expect.eq(ValueIndex.ItemValue("cryptling", "misprint_trophy"), 0, "untradeable is worth 0")

	local total = ValueIndex.OfferValue({ caseStubsOrTiers = { 2, 3 }, cryptlings = { smudge = 2, sploot = 1 } })
	expect.eq(total, 4 + 9 + 2 + 10, "mixed offer sums")
end)

test("ComputeValueVerdict warns AGAINST the side giving more value", function()
	local godlySide = { tiers = {}, cryptlings = { prototype_zero = 1 } } -- 400
	local commonSide = { tiers = {}, cryptlings = { smudge = 1 } } -- 1

	local values, warning, against = TradeFlow.ComputeValueVerdict(godlySide :: any, commonSide :: any)
	expect.deepEq(values, { 400, 1 }, "both sides valued")
	expect.eq(warning, true, "godly-for-common warns")
	expect.eq(against, 1, "warning is against the godly giver (side A)")

	local values2, warning2, against2 = TradeFlow.ComputeValueVerdict(commonSide :: any, godlySide :: any)
	expect.deepEq(values2, { 1, 400 }, "mirrored values")
	expect.ok(warning2 == true and against2 == 2, "mirrored warning against side B")

	local fairA = { tiers = { 2, 2 }, cryptlings = {} } -- 8
	local fairB = { tiers = {}, cryptlings = { sploot = 1 } } -- 10
	local _, fairWarn = TradeFlow.ComputeValueVerdict(fairA :: any, fairB :: any)
	expect.eq(fairWarn, false, "near-even trade stays quiet")

	local emptyValues, emptyWarn =
		TradeFlow.ComputeValueVerdict({ tiers = {}, cryptlings = {} } :: any, { tiers = {}, cryptlings = {} } :: any)
	expect.deepEq(emptyValues, { 0, 0 }, "empty sides value to 0")
	expect.eq(emptyWarn, false, "empty sides never warn")
end)

return { name = "trading state machine (TradeFlow + ValueIndex)", tests = tests }
