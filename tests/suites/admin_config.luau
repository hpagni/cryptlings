--!strict
-- Admin config suite (Addendum 3 R4-1; LOBBY_BUILD_PLAN_R4 WP1.7). Pure-data
-- pins over Shared.Config.AdminConfig plus the PriceLadder/ProductCatalog rows
-- that AdminService.UnlockAll walks, so the /unlockall grant loop's standing
-- assumptions — allowlist of record, rate-limit bucket, the 3-step housing
-- chain order, the skip sets — hold still without booting a server. No
-- Roblox instance APIs: lune-requirable by construction (AdminConfig is a
-- frozen table; adminship ships by editing that file — no DataStore by
-- design).

local AdminConfig = require("../../src/shared/Config/AdminConfig")
local PriceLadder = require("../../src/shared/Economy/PriceLadder")
local ProductCatalog = require("../../src/shared/Economy/ProductCatalog")
local expect = require("../expect")

local tests = {}
local function test(name: string, fn: () -> ())
	table.insert(tests, { name = name, fn = fn })
end

-- The exact 3-step upgrade chain UnlockAll grants IN ORDER. Order is
-- load-bearing: MonetizationService's requiresHousingTier refusal means each
-- grant must satisfy the next step's prerequisite (0 -> 1 -> 2, ending at
-- tier 3); dataService.Update is synchronous, so the chain works in one loop.
local HOUSING_CHAIN = { "HOUSING_HOUSE", "HOUSING_TWO_STORY_UP", "HOUSING_MANSION_UP_TWO_STORY" }

-- The redundant direct/skip housing rows the generic UnlockAll loop must
-- skip (granting any of them would race the chain or waste a tier raise).
local HOUSING_SKIPPED = { "HOUSING_TWO_STORY", "HOUSING_MANSION", "HOUSING_MANSION_UP_HOUSE" }

test("allowlist of record: creator userId 85875119 is a permanent admin; tables frozen", function()
	expect.ok(table.isfrozen(AdminConfig :: any), "AdminConfig is frozen")
	expect.ok(table.isfrozen(AdminConfig.Admins :: any), "Admins is frozen")
	expect.eq(AdminConfig.Admins[85875119], true, "creator userId in the shipped allowlist")
end)

test("rate limit of record: 5 commands / 10 s token bucket", function()
	expect.ok(table.isfrozen(AdminConfig.RateLimit :: any), "RateLimit is frozen")
	expect.eq(AdminConfig.RateLimit.max, 5, "bucket max of record")
	expect.eq(AdminConfig.RateLimit.windowSec, 10, "bucket window of record")
end)

test("housing chain: requiresHousingTier ascends 0/1/2 and every step is wired", function()
	for index, sku in HOUSING_CHAIN do
		local row = PriceLadder.GetRow(sku)
		expect.ok(row ~= nil, `{sku} present in the ladder`)
		expect.eq((row :: any).wiredInMvp, true, `{sku} wiredInMvp`)
		local productSpec = (ProductCatalog.BySku :: any)[sku]
		expect.ok(productSpec ~= nil, `{sku} present in the catalog`)
		expect.eq(productSpec.requiresHousingTier, index - 1, `{sku} prerequisite tier (chain step {index})`)
	end
end)

test("the three redundant housing skip rows exist (the generic loop skips something real)", function()
	for _, sku in HOUSING_SKIPPED do
		expect.ok(PriceLadder.GetRow(sku) ~= nil, `{sku} present in the ladder`)
	end
end)

test("exactly 3 ladder rows are wiredInMvp == false (the [ADMIN] skipped census of record)", function()
	local notWired = 0
	for _, row in PriceLadder.Rows do
		if row.wiredInMvp == false then
			notWired += 1
		end
	end
	expect.eq(notWired, 3, "not-wired row count of record")
end)

return { name = "admin config (AdminConfig + housing chain)", tests = tests }
