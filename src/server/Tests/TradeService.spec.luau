--!strict
-- CRYPTLINGS: NIGHT SHIFT — TradeService spec (Stage 4 "Swap-meet trading";
-- SOP §3.1 ④, §3.3, §8.1, §8.2; contracts §B, §C, §D). TestEZ-style: run in
-- Studio via TestEZ (`Packages`/`DevPackages` testez) pointed at
-- ServerScriptService.Server.Tests.
--
-- TradeService ships its §8.2 single write path as PURE seams (no Roblox
-- state, plain profile-data tables) exactly so this spec can drive them with
-- PlayerDataService mock-mode-shaped profiles (Util.DeepCopy of
-- ProfileTemplate) and no live players:
--   TradeService.SanitizeOffer(raw) -> (caseUids?, cryptlings?, err?)
--   TradeService.OfferAvailable(data, caseUids, cryptlings) -> boolean
--   TradeService.TakeOfferFromData(data, caseUids, cryptlings) -> {CaseStub}?
--   TradeService.GrantToData(data, stubs, cryptlings, record?)
--
-- Economy-critical launch blockers covered (§8.2 trade-dupe + data-loss):
--   * atomic swap moves the EXACT case uids and cryptling counts both ways
--     (and lands the contract-§D tradeHistory record on both profiles)
--   * the same case uid committed to two concurrent trades -> the second
--     take fails revalidation with the profile untouched (dupe-proofing)
--   * take is validate-all-then-mutate: ANY miss leaves the profile untouched
--   * non-tradeable / unknown / duplicated / malformed ids rejected at
--     SetOffer time (SanitizeOffer) AND at execute time (TakeOfferFromData)
--   * the server-side value verdict (ValueIndex) flags lopsided trades and
--     the TradeLedger record round-trips the valueWarning flag (§8.1, §5.4)
--
-- Confirm-stage FSM behaviors (offer change resets both stages; stage 2 only
-- >=3s after both stage 1; valueWarning recompute; completed-trade ledger
-- append) run through TradeService's Studio-only ForTest seams
-- (CreateSessionForTest / SetOfferForTest / ConfirmForTest / SetClockForTest)
-- with PlayerDataService.LoadMockProfileForTest fixtures — the real handlers
-- and the real atomic execute path, headless. The block degrades to SKIP when
-- the seams are unavailable (non-Studio).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Types = require(Shared:WaitForChild("Types"))
local Util = require(Shared:WaitForChild("Util"))

local TRADE_HISTORY_MAX = 30 -- contract §D: profile.tradeHistory ring size

local function requireServerModule(parentName: string?, name: string): any
	local testsFolder = script.Parent
	local serverRoot = testsFolder and testsFolder.Parent
	local container: Instance? = serverRoot
	if parentName ~= nil and serverRoot ~= nil then
		container = serverRoot:FindFirstChild(parentName)
	end
	local module = container and container:FindFirstChild(name)
	if module == nil or not module:IsA("ModuleScript") then
		return nil
	end
	local ok, result = pcall(require, module)
	if ok then
		return result
	end
	return nil
end

local function requireValueIndex(): any
	local economy = Shared:FindFirstChild("Economy")
	local module = economy and economy:FindFirstChild("ValueIndex")
	if module == nil or not module:IsA("ModuleScript") then
		return nil
	end
	local ok, result = pcall(require, module)
	if ok and type(result) == "table" then
		return result
	end
	return nil
end

return function()
	-- TestEZ injects describe/it/expect into this function's environment
	-- (setfenv). Localize through getfenv so the file stays --!strict clean.
	local env = getfenv() :: any
	local describe: (string, () -> ()) -> () = env.describe
	local it: (string, () -> ()) -> () = env.it
	local itSKIP: (string, () -> ()) -> () = env.itSKIP
	local expect: (any) -> any = env.expect
	if type(describe) ~= "function" or type(it) ~= "function" or type(expect) ~= "function" then
		warn(
			"[TradeService.spec] TestEZ globals missing — run via TestEZ from Packages/DevPackages"
				.. " (wally install); spec skipped"
		)
		return
	end

	local TradeService = requireServerModule("Services", "TradeService")
	local TradeLedger = requireServerModule("Services", "TradeLedger")
	local ProfileTemplate = requireServerModule(nil, "ProfileTemplate")
	local ValueIndex = requireValueIndex()

	if TradeService == nil or ProfileTemplate == nil then
		warn(
			"[TradeService.spec] TradeService/ProfileTemplate not found under ServerScriptService.Server"
				.. " — Stage 4 trade-server module not present; spec skipped (it runs once the module lands)"
		)
		describe("TradeService", function()
			itSKIP("requires Services/TradeService.luau (Stage 4 trade-server module)", function() end)
		end)
		return
	end
	if
		type(TradeService.SanitizeOffer) ~= "function"
		or type(TradeService.OfferAvailable) ~= "function"
		or type(TradeService.TakeOfferFromData) ~= "function"
		or type(TradeService.GrantToData) ~= "function"
	then
		warn(
			"[TradeService.spec] TradeService is missing its pure test seams (SanitizeOffer/OfferAvailable/"
				.. "TakeOfferFromData/GrantToData) — contract drift, see the spec header; spec skipped"
		)
		describe("TradeService", function()
			itSKIP("requires the documented pure seams on TradeService", function() end)
		end)
		return
	end

	----------------------------------------------------------------------------
	-- Fixtures: mock-mode-shaped profiles (the same template PlayerDataService
	-- mock profiles deep-copy) + deterministic case stubs.
	----------------------------------------------------------------------------

	local function newProfile(): Types.ProfileData
		return Util.DeepCopy(ProfileTemplate :: Types.ProfileData)
	end

	local stubCounter = 0
	local function makeStub(tier: number): Types.CaseStub
		stubCounter += 1
		return {
			uid = `TRADESPEC-{stubCounter}`,
			tier = tier,
			lineId = "line1",
			acquiredAt = os.time(),
			source = "run" :: Types.CaseSource,
		}
	end

	local function ownsUid(data: Types.ProfileData, uid: string): boolean
		for _, stub in data.locker.cases do
			if stub.uid == uid then
				return true
			end
		end
		return false
	end

	----------------------------------------------------------------------------
	-- SanitizeOffer — the SetOffer-time input gate
	----------------------------------------------------------------------------

	describe("TradeService.SanitizeOffer (SetOffer input gate)", function()
		it("accepts and normalizes a valid offer", function()
			local caseUids, cryptlings, err = TradeService.SanitizeOffer({
				caseUids = { "uid-a", "uid-b" },
				cryptlings = { smudge = 2, wonk = 1 },
			})
			expect(err).never.to.be.ok()
			expect(caseUids).to.be.ok()
			expect(cryptlings).to.be.ok()
			assert(caseUids ~= nil and cryptlings ~= nil, "narrowed above")
			expect(#caseUids).to.equal(2)
			expect(cryptlings.smudge).to.equal(2)
			expect(cryptlings.wonk).to.equal(1)
		end)

		it("accepts an empty offer (one-sided gifts are valueWarning territory, not errors)", function()
			local caseUids, cryptlings, err = TradeService.SanitizeOffer({})
			expect(err).never.to.be.ok()
			assert(caseUids ~= nil and cryptlings ~= nil, "narrowed above")
			expect(#caseUids).to.equal(0)
			expect(next(cryptlings)).never.to.be.ok()
		end)

		it("rejects the non-tradeable misprint_trophy with NOT_TRADEABLE (§4.2/§8.1)", function()
			local caseUids, _, err = TradeService.SanitizeOffer({ cryptlings = { misprint_trophy = 1 } })
			expect(caseUids).never.to.be.ok()
			expect(err).to.equal("NOT_TRADEABLE")
		end)

		it("rejects unknown roster ids", function()
			local caseUids, _, err = TradeService.SanitizeOffer({ cryptlings = { not_a_real_cryptling = 1 } })
			expect(caseUids).never.to.be.ok()
			expect(err).to.be.ok()
		end)

		it("rejects malformed counts (zero, negative, fractional, NaN)", function()
			for _, badCount in { 0, -1, 1.5, 0 / 0 } do
				local caseUids, _, err = TradeService.SanitizeOffer({ cryptlings = { smudge = badCount } })
				expect(caseUids).never.to.be.ok()
				expect(err).to.be.ok()
			end
		end)

		it("rejects the same case uid offered twice (double-spend attempt)", function()
			local caseUids, _, err = TradeService.SanitizeOffer({ caseUids = { "uid-a", "uid-a" } })
			expect(caseUids).never.to.be.ok()
			expect(err).to.be.ok()
		end)

		it("rejects non-table payloads", function()
			for _, payload in { 5 :: any, "offer" :: any, true :: any } do
				local caseUids, _, err = TradeService.SanitizeOffer(payload)
				expect(caseUids).never.to.be.ok()
				expect(err).to.be.ok()
			end
		end)
	end)

	----------------------------------------------------------------------------
	-- OfferAvailable — the SetOffer-time ownership soft gate
	----------------------------------------------------------------------------

	describe("TradeService.OfferAvailable (ownership soft gate)", function()
		it("passes when every uid and count is owned", function()
			local data = newProfile()
			local stub = makeStub(2)
			table.insert(data.locker.cases, stub)
			data.collection.smudge = 3
			expect(TradeService.OfferAvailable(data, { stub.uid }, { smudge = 2 })).to.equal(true)
		end)

		it("fails on an unowned case uid", function()
			local data = newProfile()
			expect(TradeService.OfferAvailable(data, { "uid-missing" }, {})).to.equal(false)
		end)

		it("fails when counts exceed the collection", function()
			local data = newProfile()
			data.collection.smudge = 1
			expect(TradeService.OfferAvailable(data, {}, { smudge = 2 })).to.equal(false)
		end)
	end)

	----------------------------------------------------------------------------
	-- Atomic swap — TakeOfferFromData + GrantToData (§8.2 single write path,
	-- mirroring TradeService.doSwap exactly)
	----------------------------------------------------------------------------

	describe("Atomic swap (TakeOfferFromData + GrantToData)", function()
		it("moves the exact case uids and cryptling counts both ways", function()
			local dataA = newProfile()
			local dataB = newProfile()
			local caseX = makeStub(2)
			local caseY = makeStub(1)
			table.insert(dataA.locker.cases, caseX)
			dataA.collection.wonk = 2
			table.insert(dataB.locker.cases, caseY)
			dataB.collection.smudge = 3

			local offerA = { caseUids = { caseX.uid }, cryptlings = { wonk = 1 } }
			local offerB = { caseUids = { caseY.uid }, cryptlings = { smudge = 2 } }

			local takenA = TradeService.TakeOfferFromData(dataA, offerA.caseUids, offerA.cryptlings)
			local takenB = TradeService.TakeOfferFromData(dataB, offerB.caseUids, offerB.cryptlings)
			expect(takenA).to.be.ok()
			expect(takenB).to.be.ok()
			assert(takenA ~= nil and takenB ~= nil, "narrowed above")
			expect(#takenA).to.equal(1)
			expect(takenA[1].uid).to.equal(caseX.uid)
			expect(#takenB).to.equal(1)
			expect(takenB[1].uid).to.equal(caseY.uid)

			local now = os.time()
			local recordA: Types.TradeRecord = {
				tradeId = "trade-1",
				partnerId = 222,
				gave = { cases = table.clone(offerA.caseUids), cryptlings = table.clone(offerA.cryptlings) },
				got = { cases = table.clone(offerB.caseUids), cryptlings = table.clone(offerB.cryptlings) },
				at = now,
			}
			local recordB: Types.TradeRecord = {
				tradeId = "trade-1",
				partnerId = 111,
				gave = { cases = table.clone(offerB.caseUids), cryptlings = table.clone(offerB.cryptlings) },
				got = { cases = table.clone(offerA.caseUids), cryptlings = table.clone(offerA.cryptlings) },
				at = now,
			}
			TradeService.GrantToData(dataA, takenB, offerB.cryptlings, recordA)
			TradeService.GrantToData(dataB, takenA, offerA.cryptlings, recordB)

			-- Cases: exact uids crossed over, nothing duplicated or lost.
			expect(ownsUid(dataA, caseY.uid)).to.equal(true)
			expect(ownsUid(dataA, caseX.uid)).to.equal(false)
			expect(ownsUid(dataB, caseX.uid)).to.equal(true)
			expect(ownsUid(dataB, caseY.uid)).to.equal(false)
			expect(#dataA.locker.cases).to.equal(1)
			expect(#dataB.locker.cases).to.equal(1)

			-- Cryptling counts: exact amounts moved, remainders intact.
			expect(dataA.collection.wonk).to.equal(1)
			expect(dataA.collection.smudge).to.equal(2)
			expect(dataB.collection.smudge).to.equal(1)
			expect(dataB.collection.wonk).to.equal(1)

			-- Contract §D: tradeHistory summary on BOTH profiles.
			local historyA = dataA.tradeHistory[#dataA.tradeHistory]
			local historyB = dataB.tradeHistory[#dataB.tradeHistory]
			expect(historyA.tradeId).to.equal("trade-1")
			expect(historyB.tradeId).to.equal("trade-1")
			expect(historyA.partnerId).to.equal(222)
			expect(historyB.partnerId).to.equal(111)
			expect(table.find(historyA.gave.cases, caseX.uid)).to.be.ok()
			expect(table.find(historyA.got.cases, caseY.uid)).to.be.ok()
		end)

		it("is all-or-nothing: ANY missing item leaves the profile untouched", function()
			local data = newProfile()
			local caseX = makeStub(2)
			table.insert(data.locker.cases, caseX)
			data.collection.wonk = 1

			-- One owned case + one phantom uid + an owned cryptling: nothing moves.
			local taken = TradeService.TakeOfferFromData(data, { caseX.uid, "uid-phantom" }, { wonk = 1 })
			expect(taken).never.to.be.ok()
			expect(#data.locker.cases).to.equal(1)
			expect(ownsUid(data, caseX.uid)).to.equal(true)
			expect(data.collection.wonk).to.equal(1)

			-- Same when only the cryptling side is short.
			local taken2 = TradeService.TakeOfferFromData(data, { caseX.uid }, { wonk = 2 })
			expect(taken2).never.to.be.ok()
			expect(#data.locker.cases).to.equal(1)
			expect(data.collection.wonk).to.equal(1)
		end)

		it("fails revalidation when the same uid is committed to two concurrent trades", function()
			local dataA = newProfile()
			local dataB = newProfile()
			local caseX = makeStub(2)
			table.insert(dataA.locker.cases, caseX)

			-- Trade 1 executes first: caseX legitimately leaves A for B.
			local taken1 = TradeService.TakeOfferFromData(dataA, { caseX.uid }, {})
			expect(taken1).to.be.ok()
			assert(taken1 ~= nil, "narrowed above")
			TradeService.GrantToData(dataB, taken1, {}, nil)

			-- Trade 2 still references caseX: execute-time revalidation MUST fail
			-- and leave A untouched (the §8.2 dupe guarantee).
			local taken2 = TradeService.TakeOfferFromData(dataA, { caseX.uid }, {})
			expect(taken2).never.to.be.ok()

			-- The uid exists EXACTLY once across the economy.
			local copies = 0
			for _, data in { dataA, dataB } do
				if ownsUid(data, caseX.uid) then
					copies += 1
				end
			end
			expect(copies).to.equal(1)
			expect(ownsUid(dataB, caseX.uid)).to.equal(true)
		end)

		it("rejects duplicate uids inside one offer at take time (double-spend)", function()
			local data = newProfile()
			local caseX = makeStub(2)
			table.insert(data.locker.cases, caseX)
			local taken = TradeService.TakeOfferFromData(data, { caseX.uid, caseX.uid }, {})
			expect(taken).never.to.be.ok()
			expect(#data.locker.cases).to.equal(1)
		end)

		it("rejects untradeable ids at take time even when the count is owned", function()
			local data = newProfile()
			data.collection.misprint_trophy = 1 -- starter-pack grant lives in collection
			local taken = TradeService.TakeOfferFromData(data, {}, { misprint_trophy = 1 })
			expect(taken).never.to.be.ok()
			expect(data.collection.misprint_trophy).to.equal(1)
		end)

		it(`caps tradeHistory at the {TRADE_HISTORY_MAX}-entry contract ring (§D)`, function()
			local data = newProfile()
			for index = 1, TRADE_HISTORY_MAX + 1 do
				local record: Types.TradeRecord = {
					tradeId = `trade-{index}`,
					partnerId = 999,
					gave = { cases = {}, cryptlings = {} },
					got = { cases = {}, cryptlings = {} },
					at = os.time(),
				}
				TradeService.GrantToData(data, {}, {}, record)
			end
			expect(#data.tradeHistory).to.equal(TRADE_HISTORY_MAX)
			expect(data.tradeHistory[1].tradeId).to.equal("trade-2") -- oldest dropped
			expect(data.tradeHistory[TRADE_HISTORY_MAX].tradeId).to.equal(`trade-{TRADE_HISTORY_MAX + 1}`)
		end)
	end)

	----------------------------------------------------------------------------
	-- ValueIndex — the server-computed value verdict (§8.1 scam mitigations)
	----------------------------------------------------------------------------

	describe("ValueIndex (server-computed value warnings)", function()
		if ValueIndex == nil then
			warn("[TradeService.spec] Shared.Economy.ValueIndex missing — value-warning tests skipped")
			itSKIP("requires Shared/Economy/ValueIndex.luau (Stage 4 shared module)", function() end)
			return
		end

		it("values items by rarity and case tier; untradeable/unknown are worth 0", function()
			expect(ValueIndex.ItemValue("cryptling", "smudge")).to.equal(ValueIndex.BASE_VALUES.Common)
			expect(ValueIndex.ItemValue("cryptling", "prototype_zero")).to.equal(ValueIndex.BASE_VALUES.Godly)
			expect(ValueIndex.ItemValue("cryptling", "misprint_trophy")).to.equal(0)
			expect(ValueIndex.ItemValue("cryptling", "not_a_real_cryptling")).to.equal(0)
			for tier = 1, 3 do
				expect(ValueIndex.ItemValue("case", tier)).to.equal(ValueIndex.CASE_VALUES[tier])
			end
			expect(ValueIndex.IsTradeable("smudge")).to.equal(true)
			expect(ValueIndex.IsTradeable("misprint_trophy")).to.equal(false)
		end)

		it("sums offers over stubs, bare tiers, and cryptling counts", function()
			local stub = makeStub(2)
			local value = ValueIndex.OfferValue({
				caseStubsOrTiers = { stub, 3 },
				cryptlings = { smudge = 2, sploot = 1 },
			})
			local expected = ValueIndex.CASE_VALUES[2]
				+ ValueIndex.CASE_VALUES[3]
				+ 2 * ValueIndex.BASE_VALUES.Common
				+ ValueIndex.BASE_VALUES.Rare
			expect(value).to.equal(expected)
		end)

		it("flags godly-for-common as lopsided; mirrored trades stay fair", function()
			local godlySide = ValueIndex.OfferValue({ cryptlings = { prototype_zero = 1 } })
			local commonSide = ValueIndex.OfferValue({ cryptlings = { smudge = 1 } })
			expect(ValueIndex.IsLopsided(godlySide, commonSide)).to.equal(true)
			expect(ValueIndex.IsLopsided(commonSide, godlySide)).to.equal(true) -- symmetric
			expect(ValueIndex.IsLopsided(godlySide, godlySide)).to.equal(false)
			expect(ValueIndex.Compare(godlySide, commonSide).warn).to.equal(true)
			expect(ValueIndex.Compare(godlySide, godlySide).ratio).to.equal(1)
		end)

		it("stays quiet below the trivial-trade floor; flags something-for-nothing", function()
			-- 2 Commons for 1 Common: ratio 2x but max value < floor -> quiet.
			expect(ValueIndex.IsLopsided(2, 1)).to.equal(false)
			expect(ValueIndex.IsLopsided(0, 0)).to.equal(false)
			-- A Rare for nothing clears the floor -> warn.
			expect(ValueIndex.IsLopsided(ValueIndex.BASE_VALUES.Rare, 0)).to.equal(true)
			expect(ValueIndex.Compare(ValueIndex.BASE_VALUES.Rare, 0).ratio).to.equal(math.huge)
		end)

		it("prices sealed cases below their expected open value (sealed discount)", function()
			for tier = 1, 3 do
				expect(ValueIndex.CASE_VALUES[tier] < ValueIndex.ExpectedOpenValue(tier)).to.equal(true)
			end
			-- Documented derivation: EV(T2) = 6.70 at the disclosed baseline odds.
			expect(math.abs(ValueIndex.ExpectedOpenValue(2) - 6.7) < 1e-9).to.equal(true)
		end)
	end)

	----------------------------------------------------------------------------
	-- TradeLedger — the §3.3 rollback log of record
	----------------------------------------------------------------------------

	describe("TradeLedger (TradeLedger_v1 rollback log)", function()
		if TradeLedger == nil or type(TradeLedger.Append) ~= "function" or type(TradeLedger.Get) ~= "function" then
			warn("[TradeService.spec] Services/TradeLedger missing — ledger tests skipped")
			itSKIP("requires Services/TradeLedger.luau (Stage 4 trade-server module)", function() end)
			return
		end

		it("round-trips an Append'd record carrying the valueWarning flag", function()
			local tradeId = `TRADESPEC-LEDGER-{math.floor(os.clock() * 1e6)}`
			local record = {
				tradeId = tradeId,
				ts = os.time(),
				jobId = game.JobId,
				sides = {
					["111"] = { userId = 111, playerName = "SpecA", gaveCases = {}, gaveCryptlings = { smudge = 1 } },
					["222"] = {
						userId = 222,
						playerName = "SpecB",
						gaveCases = {},
						gaveCryptlings = { prototype_zero = 1 },
					},
				},
				valueWarning = true, -- the §5.4 scam-review flag of record
			}
			-- In Studio without DataStore access Append returns false (memory
			-- cache only) — either way the record must be retrievable.
			local durable = TradeLedger.Append(record)
			expect(type(durable)).to.equal("boolean")

			record.valueWarning = false -- caller mutation must not corrupt the stored copy

			local stored = TradeLedger.Get(tradeId)
			expect(stored).to.be.ok()
			assert(stored ~= nil, "narrowed above")
			expect(stored.tradeId).to.equal(tradeId)
			expect(stored.valueWarning).to.equal(true)
			expect(stored.sides["111"].gaveCryptlings.smudge).to.equal(1)
			expect(stored.sides["222"].gaveCryptlings.prototype_zero).to.equal(1)
		end)

		it("rejects records without a tradeId", function()
			expect(TradeLedger.Append({} :: any)).to.equal(false)
			expect(TradeLedger.Append({ tradeId = "" } :: any)).to.equal(false)
			expect(TradeLedger.Get("")).never.to.be.ok()
		end)
	end)

	----------------------------------------------------------------------------
	-- Session FSM behaviors — driven headless through TradeService's Studio-only
	-- ForTest seams (CreateSessionForTest + module-level handler entry points +
	-- SetClockForTest) with PlayerDataService.LoadMockProfileForTest fixtures.
	-- The seams call the REAL onSetOffer/onConfirm/onCancel handlers and the
	-- real atomic execute path; only the invite preconditions (hub/range/rate
	-- limit) are bypassed.
	----------------------------------------------------------------------------

	describe("Trade session FSM (ForTest seams)", function()
		local PlayerDataService = requireServerModule("Services", "PlayerDataService")
		local hasSeams = type(TradeService.CreateSessionForTest) == "function"
			and type(TradeService.SetOfferForTest) == "function"
			and type(TradeService.ConfirmForTest) == "function"
			and type(TradeService.CancelForTest) == "function"
			and type(TradeService.GetSessionStateForTest) == "function"
			and type(TradeService.SetClockForTest) == "function"
		local hasMockProfiles = PlayerDataService ~= nil
			and type(PlayerDataService.LoadMockProfileForTest) == "function"
			and type(PlayerDataService.ReleaseMockProfileForTest) == "function"
		if not hasSeams or not hasMockProfiles then
			warn(
				"[TradeService.spec] TradeService ForTest seams / PlayerDataService mock-profile seams"
					.. " unavailable (Studio-only) — FSM tests skipped"
			)
			itSKIP("resets BOTH confirm stages to 0 when either offer changes", function() end)
			itSKIP("rejects stage-2 confirms until >=3s after BOTH stage-1 confirms", function() end)
			itSKIP("computes TradeState.valueWarning via ValueIndex on every offer change", function() end)
			itSKIP("appends the completed-trade ledger record with the session's valueWarning", function() end)
			return
		end

		-- ValueIndex/TradeLedger-dependent tests degrade to SKIP, not failures,
		-- if those parallel modules are absent.
		local itValue = if ValueIndex ~= nil then it else itSKIP
		local itLedger = if ValueIndex ~= nil and TradeLedger ~= nil then it else itSKIP

		type Fixture = { a: any, b: any, tradeId: string, done: () -> () }

		local fixtureUserId = 90000200
		local function openSession(): Fixture
			fixtureUserId += 2
			local a: any = {
				UserId = fixtureUserId,
				Name = `TradeSpecA{fixtureUserId}`,
				DisplayName = "TradeSpecA",
				Parent = nil,
			}
			local b: any = {
				UserId = fixtureUserId + 1,
				Name = `TradeSpecB{fixtureUserId + 1}`,
				DisplayName = "TradeSpecB",
				Parent = nil,
			}
			assert(PlayerDataService.LoadMockProfileForTest(a) ~= nil, "mock profile A failed to load")
			assert(PlayerDataService.LoadMockProfileForTest(b) ~= nil, "mock profile B failed to load")
			-- A holds the jackpot Godly; B holds a single Common — a maximally
			-- lopsided pairing under ValueIndex.BASE_VALUES (400 vs 1).
			PlayerDataService.Update(a, function(data: Types.ProfileData)
				data.collection.prototype_zero = 1
			end)
			PlayerDataService.Update(b, function(data: Types.ProfileData)
				data.collection.smudge = 1
			end)
			local tradeId = TradeService.CreateSessionForTest(a, b)
			assert(type(tradeId) == "string", "CreateSessionForTest did not return a tradeId")
			local function done()
				TradeService.CancelForTest(a, tradeId) -- no-op once completed/closed
				TradeService.SetClockForTest(nil)
				PlayerDataService.ReleaseMockProfileForTest(a)
				PlayerDataService.ReleaseMockProfileForTest(b)
			end
			return { a = a, b = b, tradeId = tradeId, done = done }
		end

		-- pcall-wrapped test bodies so a failed expect still releases the fixture
		-- (TestEZ has no try/finally).
		local function withSession(fx: Fixture, body: () -> ())
			local ok, err = pcall(body)
			fx.done()
			if not ok then
				error(err)
			end
		end

		local function stageOf(state: Types.TradeState, playerLike: any): number
			local offer = state.players[tostring(playerLike.UserId)]
			assert(offer ~= nil, "TradeState missing this side's offer")
			return offer.confirmStage
		end

		local function bothOffer(fx: Fixture)
			expect(TradeService.SetOfferForTest(fx.a, fx.tradeId, { cryptlings = { prototype_zero = 1 } }).ok).to.equal(
				true
			)
			expect(TradeService.SetOfferForTest(fx.b, fx.tradeId, { cryptlings = { smudge = 1 } }).ok).to.equal(true)
		end

		it("resets BOTH confirm stages to 0 when either offer changes (even a no-op re-send)", function()
			local fx = openSession()
			withSession(fx, function()
				bothOffer(fx)
				expect(TradeService.ConfirmForTest(fx.a, fx.tradeId, 1).ok).to.equal(true)
				expect(TradeService.ConfirmForTest(fx.b, fx.tradeId, 1).ok).to.equal(true)
				local state = TradeService.GetSessionStateForTest(fx.tradeId)
				assert(state ~= nil, "session state missing")
				expect(stageOf(state, fx.a)).to.equal(1)
				expect(stageOf(state, fx.b)).to.equal(1)

				-- TradeUI's un-ready path re-sends the IDENTICAL offer; the contract
				-- says ANY SetOffer — including a no-op — resets both stages.
				expect(TradeService.SetOfferForTest(fx.b, fx.tradeId, { cryptlings = { smudge = 1 } }).ok).to.equal(
					true
				)
				state = TradeService.GetSessionStateForTest(fx.tradeId)
				assert(state ~= nil, "session state missing")
				expect(stageOf(state, fx.a)).to.equal(0)
				expect(stageOf(state, fx.b)).to.equal(0)
			end)
		end)

		it("rejects stage-2 confirms until >=3s after BOTH stage-1 confirms", function()
			local fakeNow = 10000
			TradeService.SetClockForTest(function()
				return fakeNow
			end)
			local fx = openSession()
			withSession(fx, function()
				bothOffer(fx)
				expect(TradeService.ConfirmForTest(fx.a, fx.tradeId, 1).ok).to.equal(true)

				-- Stage 2 before the partner's stage 1: NOT_READY.
				local early = TradeService.ConfirmForTest(fx.a, fx.tradeId, 2)
				expect(early.ok).to.equal(false)
				expect(early.err).to.equal("NOT_READY")

				expect(TradeService.ConfirmForTest(fx.b, fx.tradeId, 1).ok).to.equal(true)

				fakeNow += 2.9 -- still inside the §3.3 cool-off window
				local tooSoon = TradeService.ConfirmForTest(fx.a, fx.tradeId, 2)
				expect(tooSoon.ok).to.equal(false)
				expect(tooSoon.err).to.equal("TOO_SOON")

				fakeNow += 0.2 -- 3.1s after both stage 1: accepted
				expect(TradeService.ConfirmForTest(fx.a, fx.tradeId, 2).ok).to.equal(true)
			end)
		end)

		itValue("computes TradeState.valueWarning via ValueIndex on every offer change", function()
			local fx = openSession()
			withSession(fx, function()
				-- Godly for nothing: warning ON, against A (the higher-value giver),
				-- with both server-computed side values in the payload.
				expect(TradeService.SetOfferForTest(fx.a, fx.tradeId, { cryptlings = { prototype_zero = 1 } }).ok).to.equal(
					true
				)
				local state = TradeService.GetSessionStateForTest(fx.tradeId)
				assert(state ~= nil, "session state missing")
				expect(state.valueWarning).to.equal(true)
				expect(state.valueWarningFor).to.equal(tostring(fx.a.UserId))
				local values = state.values
				assert(values ~= nil, "TradeState.values extension missing")
				expect(values[tostring(fx.a.UserId)]).to.equal(ValueIndex.BASE_VALUES.Godly)
				expect(values[tostring(fx.b.UserId)]).to.equal(0)

				-- A empties the offer: 0 vs 0 is quiet again on the very next push.
				expect(TradeService.SetOfferForTest(fx.a, fx.tradeId, {}).ok).to.equal(true)
				state = TradeService.GetSessionStateForTest(fx.tradeId)
				assert(state ~= nil, "session state missing")
				expect(state.valueWarning).to.equal(false)
				expect(state.valueWarningFor).never.to.be.ok()
			end)
		end)

		itLedger("appends the completed-trade ledger record with the session's valueWarning", function()
			local fakeNow = 20000
			TradeService.SetClockForTest(function()
				return fakeNow
			end)
			local fx = openSession()
			withSession(fx, function()
				bothOffer(fx)
				expect(TradeService.ConfirmForTest(fx.a, fx.tradeId, 1).ok).to.equal(true)
				expect(TradeService.ConfirmForTest(fx.b, fx.tradeId, 1).ok).to.equal(true)
				fakeNow += 3.05
				expect(TradeService.ConfirmForTest(fx.a, fx.tradeId, 2).ok).to.equal(true)
				expect(TradeService.ConfirmForTest(fx.b, fx.tradeId, 2).ok).to.equal(true) -- executes

				-- The swap committed both ways and stamped tradeHistory (§D).
				local dataA = PlayerDataService.Get(fx.a) :: Types.ProfileData?
				local dataB = PlayerDataService.Get(fx.b) :: Types.ProfileData?
				assert(dataA ~= nil and dataB ~= nil, "mock profiles missing after execute")
				expect(dataA.collection.prototype_zero).never.to.be.ok()
				expect(dataA.collection.smudge).to.equal(1)
				expect(dataB.collection.prototype_zero).to.equal(1)
				expect(dataB.collection.smudge).never.to.be.ok()
				expect(dataA.tradeHistory[#dataA.tradeHistory].tradeId).to.equal(fx.tradeId)
				expect(dataB.tradeHistory[#dataB.tradeHistory].tradeId).to.equal(fx.tradeId)

				-- Ledger record of record carries the lopsided verdict (§5.4 scam
				-- review; durable SetAsync may fall back to the memory cache here).
				local record = TradeLedger.Get(fx.tradeId)
				expect(record).to.be.ok()
				assert(record ~= nil, "narrowed above")
				expect(record.valueWarning).to.equal(true)
				expect(record.sides[tostring(fx.a.UserId)].gaveCryptlings.prototype_zero).to.equal(1)
				expect(record.sides[tostring(fx.b.UserId)].gaveCryptlings.smudge).to.equal(1)
			end)
		end)
	end)
end
