--!strict
-- CRYPTLINGS: NIGHT SHIFT — pure trade-flow core (Stage 4 "Swap-meet trading";
-- SOP §3.1 ④, §3.3, §8.2). Extracted from TradeService so the economy-critical
-- FSM transitions and the single item write path are testable headless.
--
-- Pure Luau: requires no Roblox globals (lune-safe). TradeService remains the
-- server authority — it owns sessions, remotes, presence, locks, and the
-- TradeLedger; every state transition and item move it performs goes through
-- the functions in this module:
--
--   SanitizeOffer(raw) -> (caseUids?, cryptlings?, err?)
--   OfferAvailable(data, caseUids, cryptlings) -> boolean
--   TakeOfferFromData(data, caseUids, cryptlings) -> {CaseStub}?
--   GrantToData(data, stubs, cryptlings, record?)
--   NewOffers(idA, idB) -> offers map (both sides empty, stage 0)
--   ApplySetOffer(flow, userId, caseUids, cryptlings)
--       Replaces that side's offer; ANY change resets BOTH confirm stages to 0
--       and clears the stage-2 clocks (§3.3 confirm-twice).
--   ApplyConfirm(flow, userId, otherId, stage, clockNow, unixNow) -> ConfirmResult
--       The confirm-twice FSM: stage 1 (both) stamps confirmReadyClock; stage 2
--       accepted only >= TRADE_CONFIRM_STAGE2_DELAY_SECONDS later; both at
--       stage 2 => executeNow (run the atomic swap exactly once).
--   DoSwap(dataService, tradeId, playerA, playerB, offerA, offerB) -> SwapOutcome
--       Atomic execute body (§8.2): take-take-grant-grant with revalidation
--       inside each player's Update and restore on a half-failure. Caller must
--       hold WithLock on BOTH players in ascending-userId order.
--   ComputeValueVerdict(sideA, sideB) -> (values?, warning, againstIndex?)
--       ValueIndex-derived §3.3 value warning; degrades to "no warning" if
--       valuation errors — it must never block trading.

local GameConstants = require("../Config/GameConstants")
local RarityTable = require("../Config/RarityTable")
local Types = require("../Types")
local Util = require("../Util")
local ValueIndex = require("../Economy/ValueIndex")

local MAX_OFFER_CASES = GameConstants.TRADE_MAX_OFFER_CASES -- 20
local MAX_OFFER_CRYPTLING_KINDS = GameConstants.TRADE_MAX_OFFER_CRYPTLING_KINDS -- 24
local MAX_OFFER_CRYPTLING_COUNT = GameConstants.TRADE_MAX_OFFER_CRYPTLING_COUNT -- 99
local CONFIRM_STAGE2_DELAY_SECONDS = GameConstants.TRADE_CONFIRM_STAGE2_DELAY_SECONDS -- 3 (§3.3)
local TRADE_HISTORY_MAX = GameConstants.TRADE_HISTORY_MAX -- 30 (contract §D)
local MAX_UID_LENGTH = 64

--------------------------------------------------------------------------------
-- Types
--------------------------------------------------------------------------------

export type OfferState = {
	caseUids: { string },
	cryptlings: { [string]: number }, -- cryptlingId -> count
	confirmStage: number, -- 0 | 1 | 2
}

-- The FSM slice of a TradeService session (width subtyping: the live Session
-- carries extra fields and passes here unchanged).
export type FlowState = {
	userIds: { number },
	offers: { [number]: OfferState }, -- keyed by userId
	confirmReadyClock: number?, -- clockNow when BOTH hit stage 1
	stage2AtUnix: number?, -- unix time stage 2 unlocks (sent to clients)
}

export type ConfirmResult = {
	ok: boolean,
	err: string?,
	changed: boolean, -- a stage actually advanced: mark activity + fire ConfirmStage
	executeNow: boolean, -- both sides at stage 2: run the atomic execute exactly once
}

export type SwapOutcome = {
	ok: boolean,
	err: string?,
	takenA: { Types.CaseStub }?,
	takenB: { Types.CaseStub }?,
}

-- One side of a trade as resolved for valuation: offered case tiers (in offer
-- order) plus the cryptling counts.
export type ValueSide = {
	tiers: { number },
	cryptlings: { [string]: number },
}

local TradeFlow = {}

TradeFlow.CONFIRM_STAGE2_DELAY_SECONDS = CONFIRM_STAGE2_DELAY_SECONDS

--------------------------------------------------------------------------------
-- Offer validation + the §8.2 single write path
--------------------------------------------------------------------------------

-- Validates and normalizes a client-sent offer payload. Returns
-- (caseUids, cryptlings, nil) or (nil, nil, err). Rejects duplicate uids in one
-- offer (double-spend attempt), non-positive/non-integer counts, unknown ids,
-- and misprint_trophy / any tradeable == false id (contract §E).
function TradeFlow.SanitizeOffer(raw: any): ({ string }?, { [string]: number }?, string?)
	if type(raw) ~= "table" then
		return nil, nil, "BAD_OFFER"
	end

	local caseUids: { string } = {}
	local rawCases: any = (raw :: any).caseUids
	if rawCases ~= nil then
		if type(rawCases) ~= "table" then
			return nil, nil, "BAD_OFFER"
		end
		local seen: { [string]: boolean } = {}
		for key, uid in rawCases :: { [any]: any } do
			if type(key) ~= "number" or type(uid) ~= "string" or uid == "" or #uid > MAX_UID_LENGTH then
				return nil, nil, "BAD_OFFER"
			end
			if seen[uid] then
				return nil, nil, "BAD_OFFER" -- same case uid twice = dupe attempt
			end
			seen[uid] = true
			table.insert(caseUids, uid)
			if #caseUids > MAX_OFFER_CASES then
				return nil, nil, "OFFER_TOO_LARGE"
			end
		end
	end

	local cryptlings: { [string]: number } = {}
	local kinds = 0
	local rawCryptlings: any = (raw :: any).cryptlings
	if rawCryptlings ~= nil then
		if type(rawCryptlings) ~= "table" then
			return nil, nil, "BAD_OFFER"
		end
		for id, count in rawCryptlings :: { [any]: any } do
			if
				type(id) ~= "string"
				or type(count) ~= "number"
				or count ~= count -- NaN
				or count % 1 ~= 0
				or count < 1
				or count > MAX_OFFER_CRYPTLING_COUNT
			then
				return nil, nil, "BAD_OFFER"
			end
			local def = RarityTable.GetCryptling(id)
			if def == nil then
				return nil, nil, "BAD_OFFER"
			end
			if def.tradeable == false then
				return nil, nil, "NOT_TRADEABLE" -- misprint_trophy and friends (§4.2)
			end
			kinds += 1
			if kinds > MAX_OFFER_CRYPTLING_KINDS then
				return nil, nil, "OFFER_TOO_LARGE"
			end
			cryptlings[id] = count
		end
	end

	return caseUids, cryptlings, nil
end

-- Non-mutating ownership check (SetOffer-time soft gate; the hard gate is the
-- revalidation inside TakeOfferFromData at execute).
function TradeFlow.OfferAvailable(
	data: Types.ProfileData,
	caseUids: { string },
	cryptlings: { [string]: number }
): boolean
	local owned: { [string]: boolean } = {}
	for _, stub in data.locker.cases do
		owned[stub.uid] = true
	end
	for _, uid in caseUids do
		if not owned[uid] then
			return false
		end
	end
	for id, count in cryptlings do
		if (data.collection[id] or 0) < count then
			return false
		end
	end
	return true
end

-- THE take half of the single write path. Revalidates every item against the
-- live profile (uids present, counts owned, ids still tradeable), then removes
-- them uid-keyed and returns the removed CaseStubs. ANY miss returns nil with
-- `data` completely untouched (validate-all-then-mutate, §8.2).
-- Must run inside PlayerDataService.Update.
function TradeFlow.TakeOfferFromData(
	data: Types.ProfileData,
	caseUids: { string },
	cryptlings: { [string]: number }
): { Types.CaseStub }?
	-- Validate first; no mutation until everything checks out.
	local wanted: { [string]: boolean } = {}
	for _, uid in caseUids do
		if wanted[uid] then
			return nil -- duplicate uid inside one offer: double-spend attempt
		end
		wanted[uid] = true
	end
	local found = 0
	for _, stub in data.locker.cases do
		if wanted[stub.uid] then
			found += 1
		end
	end
	if found ~= #caseUids then
		return nil -- a uid raced away (opened/extracted elsewhere) since SetOffer
	end
	for id, count in cryptlings do
		local def = RarityTable.GetCryptling(id)
		if def == nil or def.tradeable == false then
			return nil
		end
		if type(count) ~= "number" or count % 1 ~= 0 or count < 1 then
			return nil
		end
		if (data.collection[id] or 0) < count then
			return nil
		end
	end

	-- Mutate: uid-keyed removal + count decrements.
	local taken: { Types.CaseStub } = {}
	for index = #data.locker.cases, 1, -1 do
		local stub = data.locker.cases[index]
		if wanted[stub.uid] then
			table.remove(data.locker.cases, index)
			table.insert(taken, stub)
			wanted[stub.uid] = nil -- a uid is taken at most once
		end
	end
	for id, count in cryptlings do
		local remaining = data.collection[id] - count
		data.collection[id] = if remaining > 0 then remaining else nil
	end
	return taken
end

-- THE grant half of the single write path: inserts the (deep-copied) case
-- stubs, increments collection counts, and appends the optional tradeHistory
-- summary (30-entry ring, contract §D). Must run inside PlayerDataService.Update.
function TradeFlow.GrantToData(
	data: Types.ProfileData,
	stubs: { Types.CaseStub },
	cryptlings: { [string]: number },
	record: Types.TradeRecord?
)
	for _, stub in stubs do
		table.insert(data.locker.cases, Util.DeepCopy(stub))
	end
	for id, count in cryptlings do
		data.collection[id] = (data.collection[id] or 0) + count
	end
	if record ~= nil then
		Util.RingAppend(data.tradeHistory :: { any }, Util.DeepCopy(record) :: any, TRADE_HISTORY_MAX)
	end
end

--------------------------------------------------------------------------------
-- Confirm-twice FSM (§3.3)
--------------------------------------------------------------------------------

-- Fresh both-sides-empty offers map for a new session.
function TradeFlow.NewOffers(idA: number, idB: number): { [number]: OfferState }
	return {
		[idA] = { caseUids = {}, cryptlings = {}, confirmStage = 0 },
		[idB] = { caseUids = {}, cryptlings = {}, confirmStage = 0 },
	}
end

-- Replaces one side's (already-sanitized) offer. ANY offer change resets BOTH
-- confirm stages to 0 and clears the stage-2 clocks (§3.3 confirm-twice).
function TradeFlow.ApplySetOffer(
	flow: FlowState,
	userId: number,
	caseUids: { string },
	cryptlings: { [string]: number }
)
	local offer = flow.offers[userId]
	offer.caseUids = caseUids
	offer.cryptlings = cryptlings

	for _, id in flow.userIds do
		flow.offers[id].confirmStage = 0
	end
	flow.confirmReadyClock = nil
	flow.stage2AtUnix = nil
end

-- One confirm press. stage must be 1 or 2 (caller validates anything else as
-- BAD_STAGE). clockNow is the monotonic session clock; unixNow is os.time()
-- (only used to stamp the client-facing stage2AtUnix).
function TradeFlow.ApplyConfirm(
	flow: FlowState,
	userId: number,
	otherId: number,
	stage: number,
	clockNow: number,
	unixNow: number
): ConfirmResult
	local offer = flow.offers[userId]
	local otherOffer = flow.offers[otherId]

	if stage == 1 then
		if offer.confirmStage >= 1 then
			return { ok = true, changed = false, executeNow = false } -- idempotent
		end
		-- A trade with literally nothing on either side cannot be confirmed.
		if
			#offer.caseUids == 0
			and next(offer.cryptlings) == nil
			and #otherOffer.caseUids == 0
			and next(otherOffer.cryptlings) == nil
		then
			return { ok = false, err = "EMPTY_TRADE", changed = false, executeNow = false }
		end
		offer.confirmStage = 1
		if otherOffer.confirmStage >= 1 and flow.confirmReadyClock == nil then
			-- Server stamps confirm-ready; stage 2 unlocks >=3s later (§3.3).
			flow.confirmReadyClock = clockNow
			flow.stage2AtUnix = unixNow + CONFIRM_STAGE2_DELAY_SECONDS
		end
		return { ok = true, changed = true, executeNow = false }
	end

	-- stage 2 (final): only >=3s after BOTH stage-1 (server-timed, never client)
	if offer.confirmStage == 0 then
		return { ok = false, err = "CONFIRM_STAGE1_FIRST", changed = false, executeNow = false }
	end
	if offer.confirmStage >= 2 then
		return { ok = true, changed = false, executeNow = false } -- idempotent
	end
	local readyClock = flow.confirmReadyClock
	if otherOffer.confirmStage < 1 or readyClock == nil then
		return { ok = false, err = "NOT_READY", changed = false, executeNow = false }
	end
	if clockNow - readyClock < CONFIRM_STAGE2_DELAY_SECONDS then
		return { ok = false, err = "TOO_SOON", changed = false, executeNow = false }
	end

	offer.confirmStage = 2
	return { ok = true, changed = true, executeNow = otherOffer.confirmStage == 2 }
end

--------------------------------------------------------------------------------
-- Atomic execute body (§8.2 — the economy-critical path)
--------------------------------------------------------------------------------

-- Runs under WithLock on BOTH players (caller's responsibility, ascending
-- userId). Take from both (each take revalidates inside that player's Update
-- write lock), restore on a half-failure, then grant both sides + tradeHistory.
-- dataService needs only .Update(player, fn) -> boolean; playerA/playerB are
-- passed through to it (only .UserId/.Name are read here).
function TradeFlow.DoSwap(
	dataService: any,
	tradeId: string,
	playerA: any,
	playerB: any,
	offerA: OfferState,
	offerB: OfferState
): SwapOutcome
	-- TAKE A
	local takenA: { Types.CaseStub }? = nil
	local tookA = dataService.Update(playerA, function(data: Types.ProfileData)
		takenA = TradeFlow.TakeOfferFromData(data, offerA.caseUids, offerA.cryptlings)
	end) == true
	if not tookA or takenA == nil then
		return { ok = false, err = "ITEMS_CHANGED" }
	end

	-- TAKE B
	local takenB: { Types.CaseStub }? = nil
	local tookB = dataService.Update(playerB, function(data: Types.ProfileData)
		takenB = TradeFlow.TakeOfferFromData(data, offerB.caseUids, offerB.cryptlings)
	end) == true
	if not tookB or takenB == nil then
		-- Half-applied: restore A's items (they never left this closure).
		local restored = dataService.Update(playerA, function(data: Types.ProfileData)
			TradeFlow.GrantToData(data, takenA :: { Types.CaseStub }, offerA.cryptlings, nil)
		end) == true
		if not restored then
			warn(
				`[TradeFlow] trade {tradeId}: failed to restore {playerA.Name}'s items after a half-applied take — manual rollback may be needed`
			)
		end
		return { ok = false, err = "ITEMS_CHANGED" }
	end

	-- GRANT both sides + history. From here the swap is committed; a grant can
	-- only fail if that profile released mid-execute (player left) — warned
	-- loudly, and the TradeLedger record enables a manual rollback (§3.3).
	local committedAt = os.time()
	local recordA: Types.TradeRecord = {
		tradeId = tradeId,
		partnerId = playerB.UserId,
		gave = { cases = table.clone(offerA.caseUids), cryptlings = table.clone(offerA.cryptlings) },
		got = { cases = table.clone(offerB.caseUids), cryptlings = table.clone(offerB.cryptlings) },
		at = committedAt,
	}
	local recordB: Types.TradeRecord = {
		tradeId = tradeId,
		partnerId = playerA.UserId,
		gave = { cases = table.clone(offerB.caseUids), cryptlings = table.clone(offerB.cryptlings) },
		got = { cases = table.clone(offerA.caseUids), cryptlings = table.clone(offerA.cryptlings) },
		at = committedAt,
	}

	local grantedA = dataService.Update(playerA, function(data: Types.ProfileData)
		TradeFlow.GrantToData(data, takenB :: { Types.CaseStub }, offerB.cryptlings, recordA)
	end) == true
	local grantedB = dataService.Update(playerB, function(data: Types.ProfileData)
		TradeFlow.GrantToData(data, takenA :: { Types.CaseStub }, offerA.cryptlings, recordB)
	end) == true
	if not grantedA then
		warn(
			`[TradeFlow] trade {tradeId}: grant to {playerA.Name} failed (left mid-execute?) — use the TradeLedger record to roll back`
		)
	end
	if not grantedB then
		warn(
			`[TradeFlow] trade {tradeId}: grant to {playerB.Name} failed (left mid-execute?) — use the TradeLedger record to roll back`
		)
	end

	return { ok = true, takenA = takenA, takenB = takenB }
end

--------------------------------------------------------------------------------
-- Value warning (§3.3 / §5.4)
--------------------------------------------------------------------------------

-- Values both sides with ValueIndex and returns ({valueA, valueB}, warning,
-- againstIndex) where againstIndex (1|2) is the side GIVING more value — the
-- side the warning is against. Any valuation error degrades to
-- (nil, false, nil): the warning is a courtesy and never blocks trading.
function TradeFlow.ComputeValueVerdict(sideA: ValueSide, sideB: ValueSide): ({ number }?, boolean, number?)
	local ok, valueA, valueB = pcall(function(): (number, number)
		return ValueIndex.OfferValue({
			caseStubsOrTiers = sideA.tiers :: { ValueIndex.CaseLike },
			cryptlings = sideA.cryptlings,
		}),
			ValueIndex.OfferValue({
				caseStubsOrTiers = sideB.tiers :: { ValueIndex.CaseLike },
				cryptlings = sideB.cryptlings,
			})
	end)
	if not ok or type(valueA) ~= "number" or type(valueB) ~= "number" then
		return nil, false, nil
	end
	local okWarn, lopsided = pcall(ValueIndex.IsLopsided, valueA, valueB)
	if okWarn and lopsided == true then
		-- The warning is AGAINST the side giving more value away.
		return { valueA, valueB }, true, if valueA >= valueB then 1 else 2
	end
	return { valueA, valueB }, false, nil
end

return table.freeze(TradeFlow)
