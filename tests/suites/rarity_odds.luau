--!strict
-- Rarity & odds suite (SOP §3.1 roster, §8.1 odds disclosure is a launch
-- blocker). Exercises the SHIPPED RarityTable — the exact module UnboxService
-- rolls with and ComplianceService discloses from.

local RarityTable = require("../../src/shared/Config/RarityTable")
local expect = require("../expect")

local tests = {}
local function test(name: string, fn: () -> ())
	table.insert(tests, { name = name, fn = fn })
end

local TIERS = { 1, 2, 3, 4, 5, 6 }

--------------------------------------------------------------------------------

test("odds table sums to exactly 1 (100%) for every tier", function()
	for _, tier in TIERS do
		local weights = RarityTable.GetWeights(tier)
		local weightTotal = 0
		for _, rarity in RarityTable.RARITY_ORDER do
			local weight = weights[rarity]
			-- tier 6 (rainbow box) legitimately zeroes the low tiers
			expect.ok(
				type(weight) == "number" and weight >= 0 and weight % 1 == 0,
				`tier {tier} {rarity} weight is a non-negative integer`
			)
			weightTotal += weight
		end
		expect.eq(weightTotal, RarityTable.WEIGHT_TOTAL, `tier {tier} weights sum`)

		local pctTotal = 0
		for _, row in RarityTable.GetOdds(tier) do
			pctTotal += row.pct
		end
		-- Each row is exact (weight share); the SUM accrues float error at the
		-- new 1e-3 resolution (e.g. 100.00000000000001), so tolerate epsilon.
		expect.near(pctTotal, 100, 1e-9, `tier {tier} disclosed odds sum to 100%`)
	end
end)

test("top tiers disclose exactly on the tier-2 baseline (L 0.5% / G 0.05% / M 0.001%)", function()
	expect.eq(RarityTable.BASELINE_TIER, 2, "baseline tier")
	local odds = RarityTable.GetOdds(2)
	local last = odds[#odds]
	expect.eq(last.rarity, "Mythical", "Mythical is the final odds row")
	expect.eq(last.pct, 0.001, "Mythical tier-2 pct (1-in-100,000)")
	expect.eq(RarityTable.GetWeights(2).Legendary, 5000, "Legendary tier-2 weight (the old Godly 0.5%)")
	expect.eq(RarityTable.GetWeights(2).Godly, 500, "Godly tier-2 weight (10x rarer)")
	expect.eq(RarityTable.GetWeights(2).Mythical, 10, "Mythical tier-2 weight")
end)

test("disclosed odds == roll data: every weight band maps to its rarity", function()
	-- RollRarity picks via cumulative integer weights out of WEIGHT_TOTAL; the
	-- disclosure (GetOdds) divides the SAME weights by 100. Probe just inside
	-- both edges of every rarity band and assert the roll lands in that rarity,
	-- so what players are told is provably what the roll path delivers (§8.1).
	for _, tier in TIERS do
		local weights = RarityTable.GetWeights(tier)
		local odds = RarityTable.GetOdds(tier)
		local cumulative = 0
		for index, rarity in RarityTable.RARITY_ORDER do
			local weight = weights[rarity]
			expect.eq(odds[index].rarity, rarity, `tier {tier} odds row {index} order`)
			expect.eq(
				odds[index].pct,
				weight * 100 / RarityTable.WEIGHT_TOTAL,
				`tier {tier} {rarity} disclosed pct == weight share`
			)

			if weight > 0 then
				local bandStart = (cumulative + 0.5) / RarityTable.WEIGHT_TOTAL
				local bandEnd = (cumulative + weight - 0.5) / RarityTable.WEIGHT_TOTAL
				expect.eq(RarityTable.RollRarity(tier, bandStart), rarity, `tier {tier} {rarity} band start`)
				expect.eq(RarityTable.RollRarity(tier, bandEnd), rarity, `tier {tier} {rarity} band end`)
			end
			cumulative += weight
		end
		expect.eq(RarityTable.RollRarity(tier, 0), if tier == 6 then "Legendary" else "Common", `tier {tier} roll 0`)
		expect.eq(RarityTable.RollRarity(tier, 0.9999999), "Mythical", `tier {tier} roll ~1`)
	end
end)

test("roster pools: 5C/6U/5R/3E/2L/2G/1M in pool; misprint_trophy excluded", function()
	local expectedPool = { Common = 5, Uncommon = 6, Rare = 5, Epic = 3, Legendary = 2, Godly = 2, Mythical = 1 }
	for rarity, count in expectedPool do
		expect.eq(#RarityTable.GetPoolByRarity(rarity), count, `{rarity} pool size`)
	end
	local trophy = RarityTable.GetCryptling("misprint_trophy")
	expect.ok(trophy ~= nil and trophy.notInPool == true, "misprint_trophy is notInPool")
	expect.eq(trophy.tradeable, false, "misprint_trophy untradeable")
	for _, def in RarityTable.GetPoolByRarity("Epic") do
		expect.neq(def.id, "misprint_trophy", "Epic pool excludes the trophy")
	end
end)

test("200k seeded tier-2 rolls approximate disclosed odds (godly within ±0.15% abs)", function()
	math.randomseed(0xC0FFEE)
	local ROLLS = 200000
	local rarityCounts: { [string]: number } = {}
	local idCounts: { [string]: number } = {}
	for _ = 1, ROLLS do
		local id = RarityTable.Roll(2, math.random)
		idCounts[id] = (idCounts[id] or 0) + 1
		local def = RarityTable.GetCryptling(id)
		expect.ok(def ~= nil and def.notInPool ~= true, `rolled id {id} is in pool`)
		rarityCounts[def.rarity] = (rarityCounts[def.rarity] or 0) + 1
	end

	for _, row in RarityTable.GetOdds(2) do
		local observedPct = (rarityCounts[row.rarity] or 0) / ROLLS * 100
		-- ±1.0% absolute is ~9 sigma at n=200k for the 50% band; godly's
		-- ±0.15% is ~9.5 sigma at p=0.005 — a miss is a logic change, not luck.
		-- Godly is 0.05% and Mythical 0.001% now: expected ~100 / ~2 hits in
		-- 200k, so give the micro-tiers a generous absolute band.
		local tolerance = if row.rarity == "Godly" or row.rarity == "Mythical" then 0.15 else 1.0
		expect.near(observedPct, row.pct, tolerance, `{row.rarity} observed% vs disclosed%`)
	end
	expect.eq(idCounts["misprint_trophy"], nil, "misprint_trophy never rolled")
	local distinct = 0
	for _ in idCounts do
		distinct += 1
	end
	-- Mythical (p = 1e-5) may legitimately miss a 200k sample; everything
	-- through Legendary must appear. Top-tier coverage is asserted from the
	-- tier-6 rainbow box below, where those pools dominate.
	expect.ok(distinct >= 21, "at least the 21 sub-Godly Cryptlings rolled")
end)

test("tier-6 rainbow box rolls Legendary+ only and covers all top crypts", function()
	math.randomseed(0xBA5EBA11)
	local idCounts: { [string]: number } = {}
	for _ = 1, 30000 do
		local id = RarityTable.Roll(6, math.random)
		local def = RarityTable.GetCryptling(id)
		expect.ok(
			def.rarity == "Legendary" or def.rarity == "Godly" or def.rarity == "Mythical",
			`rainbow box rolled {def.rarity} (must be Legendary+)`
		)
		idCounts[id] = (idCounts[id] or 0) + 1
	end
	for _, id in { "prototype_zero", "forklift", "foreman_prime", "static_king", "polychrome" } do
		expect.ok((idCounts[id] or 0) > 0, `rainbow box eventually rolls {id}`)
	end
end)

test("tier 1 and tier 3 distributions track their own disclosed odds", function()
	for _, tier in { 1, 3 } do
		math.randomseed(0x5EED + tier)
		local ROLLS = 60000
		local counts: { [string]: number } = {}
		for _ = 1, ROLLS do
			local rarity = RarityTable.RollRarity(tier, math.random())
			counts[rarity] = (counts[rarity] or 0) + 1
		end
		local weights = RarityTable.GetWeights(tier)
		for _, rarity in RarityTable.RARITY_ORDER do
			local p = weights[rarity] / RarityTable.WEIGHT_TOTAL
			local expected = ROLLS * p
			-- 4-sigma binomial tolerance plus a floor for tiny expectations.
			local tolerance = 4 * math.sqrt(ROLLS * p * (1 - p)) + 5
			expect.near(counts[rarity] or 0, expected, tolerance, `tier {tier} {rarity} count`)
		end
	end
end)

test("collectible redesign: display copy + epithets + scales are exact", function()
	-- Tier display copy of record (name cards, banners, odds rows).
	local expectedDisplay = {
		Common = "Common",
		Uncommon = "Uncommon",
		Rare = "Rare",
		Epic = "Epic",
		Legendary = "LEGENDARY",
		Godly = "GODLY",
		Mythical = "『MYTHICAL』",
	}
	local expectedTierEpithets = {
		Common = "Standard Issue",
		Uncommon = "Slightly Defective",
		Rare = "Quality Hold",
		Epic = "Containment Bin",
		Legendary = "Recall Order",
		Godly = "Management",
		Mythical = "It Got Out",
	}
	for _, rarity in RarityTable.RARITY_ORDER do
		expect.eq(RarityTable.RARITY_DISPLAY[rarity], expectedDisplay[rarity], `{rarity} display copy`)
		expect.eq(RarityTable.RARITY_EPITHETS[rarity], expectedTierEpithets[rarity], `{rarity} tier epithet`)
	end

	-- Per-def epithets, verbatim from the redesign proposal.
	local expectedEpithets = {
		smudge = "QC Failure #001",
		lintball = "Found Behind the Dryer",
		crumb = "Do Not Eat",
		wonk = "Assembled on a Friday",
		drips = "Certified Drippy",
		stitches = "Held Together, Barely",
		mopps = "Employee of the Month (Janitorial)",
		sploot = "Structural Integrity: No",
		glitch = "Render Error",
		furnace = "OSHA Violation",
		inkblot = "The Stain Spreads",
		poppo = "Do Not Pop (Somebody Popped)",
		gloop = "Non-Toxic, Probably",
		tapey = "Could Not Find the End",
		honku = "Failed Squeak Inspection",
		boxo = "This Side Up (It Was Not)",
		sproing = "Recoil Hazard",
		vacuumo = "It Ate the Small Parts Bin",
		conveyo = "Line Speed: Way Too Fast",
		forklift = "Certified Operator (License Revoked)",
		prototype_zero = "Unit 000 — Do Not Reactivate",
		foreman_prime = "The Night Shift Answers to Him",
		static_king = "All Channels. All Hail.",
		polychrome = "The Misprint That Came Out Perfect",
	}
	for id, epithet in expectedEpithets do
		local def = RarityTable.GetCryptling(id)
		expect.ok(def ~= nil, `{id} exists`)
		expect.eq(def.epithet, epithet, `{id} epithet`)
	end

	-- Brainrot display names (ids never change).
	local expectedNames = {
		smudge = "Smudgini",
		lintball = "Lint Lord",
		crumb = "Crumbus",
		wonk = "Wonkarini",
		drips = "Drippini",
		stitches = "Stitchetti",
		mopps = "Moppo Sloppo",
		sploot = "Splootus Maximus",
		glitch = "Glitcherino",
		furnace = "Furnacino Inferno",
		inkblot = "Blotto",
		poppo = "Poppo Bubblini",
		gloop = "Gloopini Snailoni",
		tapey = "Tape Tape Tapirino",
		honku = "Honk Honk Squeakini",
		boxo = "Cartoni Tortelloni",
		sproing = "Boing Boing Sproingetti",
		vacuumo = "Vacuumini Elefantini",
		conveyo = "Conveyo Slothino",
		forklift = "Forklifto Giraffeloni",
		prototype_zero = "Robo Houndini",
		foreman_prime = "Gorillionaire",
		static_king = "Staticelli Parrotelli",
		polychrome = "Axolotto Polychromo",
	}
	for id, name in expectedNames do
		local def = RarityTable.GetCryptling(id)
		expect.eq(def.name, name, `{id} display name`)
		expect.eq(def.id, id, `{id} id unchanged`)
	end

	-- Rarity size ladder: worse smaller, better bigger.
	local expectedScales = {
		Common = 0.6,
		Uncommon = 0.8,
		Rare = 1,
		Epic = 1.3,
		Legendary = 1.6,
		Godly = 2,
		Mythical = 2.5,
	}
	for _, def in RarityTable.CRYPTLINGS do
		if def.notInPool ~= true then
			expect.eq(def.scale, expectedScales[def.rarity], `{def.id} follows the rarity scale ladder`)
		end
	end
end)

test("recipes stay complete render specs (4-12 parts, every field present)", function()
	for _, def in RarityTable.CRYPTLINGS do
		expect.ok(#def.recipe >= 4 and #def.recipe <= 12, `{def.id} recipe part count ({#def.recipe})`)
		for index, recipePart in def.recipe do
			expect.ok(
				recipePart.shape ~= nil and recipePart.size ~= nil and recipePart.offset ~= nil,
				`{def.id} recipe part {index} complete`
			)
		end
	end
end)

test("rolls are uniform within a rarity (tier-2 commons split ~evenly)", function()
	math.randomseed(0xFACADE)
	local ROLLS = 90000
	local commonCounts: { [string]: number } = {}
	local commonTotal = 0
	for _ = 1, ROLLS do
		local id = RarityTable.Roll(2, math.random)
		local def = RarityTable.GetCryptling(id)
		if def.rarity == "Common" then
			commonCounts[id] = (commonCounts[id] or 0) + 1
			commonTotal += 1
		end
	end
	local pool = RarityTable.GetPoolByRarity("Common")
	for _, def in pool do
		local share = (commonCounts[def.id] or 0) / commonTotal
		expect.near(share, 1 / #pool, 0.02, `{def.id} share of common pulls`)
	end
end)

return { name = "rarity & odds (RarityTable)", tests = tests }
