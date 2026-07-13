--!strict
-- CRYPTLINGS: NIGHT SHIFT — RarityTable spec (Stage 4 economy QA; SOP §1.5,
-- §3.1, §8.1, §8.2; contract §E). TestEZ-style: run in Studio via TestEZ
-- (`Packages`/`DevPackages` testez) pointed at ServerScriptService.Server.Tests.
-- Pure-logic assertions — no players or DataStores needed:
--   * integer weights sum to WEIGHT_TOTAL (10000) for every tier
--   * disclosed odds are EXACT (pct == weight / 100) and sum to 100
--   * roster composition is 3C / 4U / 3R / 1E / 1G in-pool (12 total)
--   * RollCryptling never returns a notInPool id (misprint_trophy never drops)
--     and always returns a known id whose rarity matches the weighted pick
-- Headless distribution gate lives in tests/rarity-sim.luau (lune).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RarityTable = require(Shared:WaitForChild("Config"):WaitForChild("RarityTable"))

-- Deterministic xorshift32 -> [0, 1): reproducible roll loops without touching
-- the server RNG (all production rolls stay in UnboxService, contract §E).
local function makeRng(seed: number): () -> number
	local state = bit32.band(seed, 0xFFFFFFFF)
	assert(state ~= 0, "Rarity.spec: seed must be nonzero")
	return function(): number
		state = bit32.bxor(state, bit32.lshift(state, 13))
		state = bit32.bxor(state, bit32.rshift(state, 17))
		state = bit32.bxor(state, bit32.lshift(state, 5))
		return state / 4294967296
	end
end

return function()
	-- TestEZ injects describe/it/expect into this function's environment
	-- (setfenv). Localize through getfenv so the file stays --!strict clean.
	local env = getfenv() :: any
	local describe: (string, () -> ()) -> () = env.describe
	local it: (string, () -> ()) -> () = env.it
	local expect: (any) -> any = env.expect
	if type(describe) ~= "function" or type(it) ~= "function" or type(expect) ~= "function" then
		warn(
			"[Rarity.spec] TestEZ globals missing — run via TestEZ from Packages/DevPackages"
				.. " (wally install); spec skipped"
		)
		return
	end

	describe("RarityTable weights (contract §E)", function()
		it("sums integer weights to WEIGHT_TOTAL (10000) for every tier", function()
			expect(RarityTable.WEIGHT_TOTAL).to.equal(10000)
			for tier = 1, 3 do
				local weights = RarityTable.GetWeights(tier)
				local total = 0
				for _, rarity in RarityTable.RARITY_ORDER do
					local weight = weights[rarity]
					expect(type(weight)).to.equal("number")
					expect(weight % 1).to.equal(0) -- integer weights only
					expect(weight > 0).to.equal(true)
					total += weight
				end
				expect(total).to.equal(RarityTable.WEIGHT_TOTAL)
			end
		end)

		it("rejects invalid tiers", function()
			expect(function()
				RarityTable.GetWeights(7) -- 6 is the rainbow box now
			end).to.throw()
			expect(function()
				RarityTable.GetWeights(0)
			end).to.throw()
		end)

		it("discloses EXACT odds (pct == weight / 10000) summing to 100 (§8.1)", function()
			for tier = 1, 6 do
				local weights = RarityTable.GetWeights(tier)
				local odds = RarityTable.GetOdds(tier)
				expect(#odds).to.equal(#RarityTable.RARITY_ORDER)
				local pctTotal = 0
				for index, row in odds do
					expect(row.rarity).to.equal(RarityTable.RARITY_ORDER[index])
					expect(row.pct).to.equal(weights[row.rarity] * 100 / RarityTable.WEIGHT_TOTAL)
					pctTotal += row.pct
				end
				expect(pctTotal).to.equal(100)
			end
		end)

		it("keeps Tier 2 as the disclosed baseline with the §E weights", function()
			expect(RarityTable.BASELINE_TIER).to.equal(2)
			local tier2 = RarityTable.GetWeights(2)
			expect(tier2.Common).to.equal(499490)
			expect(tier2.Uncommon).to.equal(300000)
			expect(tier2.Rare).to.equal(150000)
			expect(tier2.Epic).to.equal(45000)
			expect(tier2.Legendary).to.equal(5000) -- the old headline 0.5%, now red
			expect(tier2.Godly).to.equal(500) -- 10x rarer than Legendary
			expect(tier2.Mythical).to.equal(10) -- the flat 1-in-100,000
		end)
	end)

	describe("Roster composition (3C/4U/3R/1E/1L/2G/1M)", function()
		it("has exactly 3/4/3/1/1/2/1 in-pool members per rarity, 15 total", function()
			local expectedPool: { [string]: number } =
				{ Common = 3, Uncommon = 4, Rare = 3, Epic = 1, Legendary = 1, Godly = 2, Mythical = 1 }
			local total = 0
			for _, rarity in RarityTable.RARITY_ORDER do
				local pool = RarityTable.GetPoolByRarity(rarity)
				expect(#pool).to.equal(expectedPool[rarity])
				for _, def in pool do
					expect(def.rarity).to.equal(rarity)
					expect(def.notInPool).never.to.equal(true)
				end
				total += #pool
			end
			expect(total).to.equal(15)
		end)

		it("keeps misprint_trophy out of every pool and untradeable (§4.2)", function()
			local trophy = RarityTable.GetCryptling("misprint_trophy")
			expect(trophy).to.be.ok()
			expect(trophy.notInPool).to.equal(true)
			expect(trophy.tradeable).to.equal(false)
			for _, rarity in RarityTable.RARITY_ORDER do
				for _, def in RarityTable.GetPoolByRarity(rarity) do
					expect(def.id).never.to.equal("misprint_trophy")
				end
			end
		end)
	end)

	describe("RollCryptling (contract §E roll path)", function()
		it("never returns a notInPool id across a seeded roll loop, all tiers", function()
			local rng = makeRng(0xBADC0DE)
			for tier = 1, 6 do
				for _ = 1, 2000 do
					local id = RarityTable.RollCryptling(tier, rng)
					local def = RarityTable.GetCryptling(id)
					expect(def).to.be.ok()
					expect(def.notInPool).never.to.equal(true)
				end
			end
		end)

		it("maps the weighted rarity pick onto that rarity's pool", function()
			local rng = makeRng(0x5EEDED)
			for _ = 1, 2000 do
				-- Re-derive the rarity from the same roll the implementation uses.
				local rarityRoll = rng()
				local memberRoll = rng()
				local expectedRarity = RarityTable.RollRarity(2, rarityRoll)
				local queue = { rarityRoll, memberRoll }
				local id = RarityTable.RollCryptling(2, function()
					return table.remove(queue, 1) :: number
				end)
				expect(RarityTable.GetCryptling(id).rarity).to.equal(expectedRarity)
			end
		end)

		it("handles the [0, 1) roll edges without escaping the table", function()
			local floorId = RarityTable.RollCryptling(2, function()
				return 0
			end)
			expect(RarityTable.GetCryptling(floorId).rarity).to.equal("Common")

			local ceilId = RarityTable.RollCryptling(2, function()
				return 0.9999999
			end)
			local ceilDef = RarityTable.GetCryptling(ceilId)
			expect(ceilDef).to.be.ok()
			expect(ceilDef.rarity).to.equal("Mythical") -- the new top of the cumulation
			expect(ceilDef.notInPool).never.to.equal(true)
		end)

		it("exposes the Stage 0 contract aliases", function()
			expect(RarityTable.RollCryptling).to.equal(RarityTable.Roll)
			expect(RarityTable.GetEntry).to.equal(RarityTable.GetCryptling)
		end)
	end)
end
