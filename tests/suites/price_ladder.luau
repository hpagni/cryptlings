--!strict
-- Price Ladder suite (SOP §4.2 — the Price Ladder of Record v1 is transcribed
-- verbatim into Economy/PriceLadder; §4.4 forbids hand-edits, so any drift from
-- the SOP numbers is a bug by definition).

local PriceLadder = require("../../src/shared/Economy/PriceLadder")
local expect = require("../expect")

local tests = {}
local function test(name: string, fn: () -> ())
	table.insert(tests, { name = name, fn = fn })
end

-- SOP §4.2 table, transcribed for the test (sku -> price R$), plus the
-- playtest combat/consumable SKUs added to the ladder of record after §4.2
-- (OPENS_RESET, EXIT_WARP, WEAPON_*).
local SOP_PRICES: { [string]: number } = {
	STARTER_PACK = 99,
	EXTRA_OPENING = 49,
	OPENS_RESET = 200,
	EXIT_WARP = 129,
	WEAPON_SWORD = 99,
	WEAPON_PAINTBALL = 79,
	WEAPON_GUN = 199,
	SCENT_SPRAY = 39,
	REVIVE_BEACON = 75,
	FOREMANS_KEY = 149,
	PET_TREATS = 249, -- equippable-pet upgrade (added with the pet feature)
	CASE_BUNDLE_S = 240,
	CASE_BUNDLE_M = 599,
	CASE_BUNDLE_L = 1499,
	CASE_BUNDLE_XL = 4999,
	CASE_BUNDLE_WHALE = 14499,
	PASS_CARRY = 349,
	PASS_2X_PAY = 449,
	PASS_VIP_LOCKER = 799,
	HOUSING_HOUSE = 499,
	HOUSING_TWO_STORY = 999,
	HOUSING_TWO_STORY_UP = 499,
	HOUSING_MANSION = 2499,
	HOUSING_MANSION_UP_HOUSE = 1999,
	HOUSING_MANSION_UP_TWO_STORY = 1499,
	PASS_MINIMAP = 499,
	PASS_GOLDEN_SET = 2999,
	SEASON_PASS = 799,
	SEASON_SKIP = 299,
	COLLECTORS_CLUB = 0, -- priced in USD (~$4.99/mo), not Robux
}

local VALID_TYPES = { DevProduct = true, GamePass = true, Subscription = true }
local VALID_SHIPS_AT = { launch = true, ["launch+2wk"] = true, season1 = true, week8 = true }

--------------------------------------------------------------------------------

test("structure integrity: every row is complete, typed, and frozen", function()
	expect.ok(table.isfrozen(PriceLadder.Rows :: any), "Rows is frozen")
	expect.ok(table.isfrozen(PriceLadder.BySku :: any), "BySku is frozen")
	expect.eq(PriceLadder.VERSION, 1, "ladder version of record")
	for index, row in PriceLadder.Rows do
		expect.ok(table.isfrozen(row :: any), `row {index} is frozen`)
		expect.ok(type(row.sku) == "string" and row.sku ~= "", `row {index} sku`)
		expect.ok(type(row.displayName) == "string" and row.displayName ~= "", `{row.sku} displayName`)
		expect.ok(VALID_TYPES[row.type] == true, `{row.sku} type valid`)
		expect.ok(
			type(row.priceRobux) == "number" and row.priceRobux >= 0 and row.priceRobux % 1 == 0,
			`{row.sku} price is a non-negative integer`
		)
		expect.ok(type(row.notes) == "string" and row.notes ~= "", `{row.sku} notes`)
		expect.ok(type(row.wiredInMvp) == "boolean", `{row.sku} wiredInMvp flag`)
		expect.ok(row.shipsAt == nil or VALID_SHIPS_AT[row.shipsAt] == true, `{row.sku} shipsAt valid`)
	end
end)

test("unique product ids: no duplicate skus or display names; BySku/GetRow agree", function()
	local seenSku: { [string]: boolean } = {}
	local seenName: { [string]: boolean } = {}
	local count = 0
	for _, row in PriceLadder.Rows do
		expect.ok(not seenSku[row.sku], `sku {row.sku} appears once`)
		expect.ok(not seenName[row.displayName], `display name "{row.displayName}" appears once`)
		seenSku[row.sku] = true
		seenName[row.displayName] = true
		expect.eq(PriceLadder.BySku[row.sku], row, `BySku[{row.sku}] is the same row object`)
		expect.eq(PriceLadder.GetRow(row.sku), row, `GetRow({row.sku})`)
		count += 1
	end
	local bySkuCount = 0
	for _ in PriceLadder.BySku do
		bySkuCount += 1
	end
	expect.eq(bySkuCount, count, "BySku has no extra entries")
	expect.eq(PriceLadder.GetRow("NO_SUCH_SKU"), nil, "GetRow on an unknown sku is nil")
end)

test("prices match SOP §4.2 exactly (full ladder, no extras, no omissions)", function()
	local expected = 0
	for _ in SOP_PRICES do
		expected += 1
	end
	expect.eq(#PriceLadder.Rows, expected, "row count == SOP product count")
	for sku, price in SOP_PRICES do
		local row = PriceLadder.GetRow(sku)
		expect.ok(row ~= nil, `{sku} present in ladder`)
		expect.eq((row :: any).priceRobux, price, `{sku} price`)
	end
end)

test("charm pricing: every Robux price ends in 9, except the documented holdouts", function()
	-- SOP §4.2: "charm pricing throughout (19/49/99 endings outconvert round
	-- numbers)". Documented holdouts: REVIVE_BEACON (75), CASE_BUNDLE_S (240 —
	-- the PS99-model ladder baseline), COLLECTORS_CLUB (USD-priced, 0 R$),
	-- OPENS_RESET (200 — shipped round; flag with economy owner whether 199 was
	-- intended, the ladder is the record until then).
	local holdouts = { REVIVE_BEACON = true, CASE_BUNDLE_S = true, COLLECTORS_CLUB = true, OPENS_RESET = true }
	for _, row in PriceLadder.Rows do
		if holdouts[row.sku] then
			expect.ok(row.priceRobux % 10 ~= 9, `{row.sku} is a real holdout (delete it from the list otherwise)`)
		else
			expect.eq(row.priceRobux % 10, 9, `{row.sku} charm ending`)
		end
	end
end)

test("bundle ladder ascends 240 -> 14,499 and the decoy anchor tops the passes", function()
	local ladder = { "CASE_BUNDLE_S", "CASE_BUNDLE_M", "CASE_BUNDLE_L", "CASE_BUNDLE_XL", "CASE_BUNDLE_WHALE" }
	local previous = 0
	for _, sku in ladder do
		local row = PriceLadder.GetRow(sku) :: any
		expect.ok(row.priceRobux > previous, `{sku} price ascends`)
		expect.eq(row.type, "DevProduct", `{sku} is a consumable dev product`)
		previous = row.priceRobux
	end

	local anchor = PriceLadder.GetRow("PASS_GOLDEN_SET") :: any
	for _, row in PriceLadder.Rows do
		if row.type == "GamePass" then
			expect.ok(row.priceRobux <= anchor.priceRobux, `{row.sku} sits under the 2,999 decoy anchor`)
		end
	end
end)

test("MVP wiring flags match the §4.1 rollout roadmap", function()
	local notWired = { SEASON_PASS = true, SEASON_SKIP = true, COLLECTORS_CLUB = true }
	for _, row in PriceLadder.Rows do
		expect.eq(row.wiredInMvp, notWired[row.sku] ~= true, `{row.sku} wiredInMvp`)
	end
end)

return { name = "price ladder (SOP §4.2)", tests = tests }
