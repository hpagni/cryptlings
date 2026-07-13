--!strict
-- Pet perks suite (equippable pets). Exercises the SHIPPED Shared.Logic.PetPerks
-- — the exact module PetService applies to Humanoid.MaxHealth and PetUI renders
-- — plus the GameConstants.PET_PERKS data of record and the PET_TREATS economy
-- rows (PriceLadder + ProductCatalog grant spec).

local GameConstants = require("../../src/shared/Config/GameConstants")
local PetPerks = require("../../src/shared/Logic/PetPerks")
local PriceLadder = require("../../src/shared/Economy/PriceLadder")
local ProductCatalog = require("../../src/shared/Economy/ProductCatalog")
local RarityTable = require("../../src/shared/Config/RarityTable")
local expect = require("../expect")

local tests = {}
local function test(name: string, fn: () -> ())
	table.insert(tests, { name = name, fn = fn })
end

local MAX_LEVEL = GameConstants.PET_UPGRADE_MAX_LEVEL -- 3
local PER_LEVEL = GameConstants.PET_UPGRADE_PERK_MULT_PER_LEVEL -- 0.25

--------------------------------------------------------------------------------

test("PET_PERKS covers every rarity in the table of record, frozen", function()
	expect.ok(table.isfrozen(GameConstants.PET_PERKS :: any), "PET_PERKS is frozen")
	for _, rarity in RarityTable.RARITY_ORDER do
		local perk = (GameConstants.PET_PERKS :: any)[rarity]
		expect.ok(perk ~= nil, `{rarity} has a pet perk`)
		expect.ok(type(perk.maxHealth) == "number" and perk.maxHealth > 0, `{rarity} maxHealth positive`)
		expect.ok(type(perk.speedBonus) == "number" and perk.speedBonus > 0, `{rarity} speedBonus positive`)
	end
end)

test("perks strictly ascend with rarity (a rarer pet is never weaker)", function()
	local previousHp = 0
	local previousSpeed = 0
	for _, rarity in RarityTable.RARITY_ORDER do
		local perk = (GameConstants.PET_PERKS :: any)[rarity]
		expect.ok(perk.maxHealth > previousHp, `{rarity} maxHealth ascends`)
		expect.ok(perk.speedBonus >= previousSpeed, `{rarity} speedBonus never descends`)
		previousHp = perk.maxHealth
		previousSpeed = perk.speedBonus
	end
end)

test("perk endpoints of record: Common +5 HP at L0, Mythical +50 HP at L0", function()
	expect.eq((PetPerks.GetPerk("Common", 0) :: any).maxHealth, 5, "Common L0 maxHealth")
	expect.eq((PetPerks.GetPerk("Mythical", 0) :: any).maxHealth, 50, "Mythical L0 maxHealth")
end)

test("ClampLevel sanitizes junk: negatives, fractions, overflow, non-numbers", function()
	expect.eq(PetPerks.ClampLevel(0), 0, "level 0 passes through")
	expect.eq(PetPerks.ClampLevel(MAX_LEVEL), MAX_LEVEL, "the cap passes through")
	expect.eq(PetPerks.ClampLevel(-2), 0, "negative clamps to 0")
	expect.eq(PetPerks.ClampLevel(1.7), 1, "fraction floors")
	expect.eq(PetPerks.ClampLevel(99), MAX_LEVEL, "overflow clamps to the cap")
	expect.eq(PetPerks.ClampLevel("3" :: any), 0, "string rejects to 0")
	expect.eq(PetPerks.ClampLevel(nil :: any), 0, "nil rejects to 0")
	expect.eq(PetPerks.ClampLevel(0 / 0), 0, "NaN rejects to 0")
end)

test("Multiplier: 1 + 0.25/level — 1x, 1.25x, 1.5x, 1.75x (capped)", function()
	expect.eq(PetPerks.Multiplier(0), 1, "level 0")
	for level = 1, MAX_LEVEL do
		expect.near(PetPerks.Multiplier(level), 1 + PER_LEVEL * level, 1e-9, `level {level}`)
	end
	expect.eq(PetPerks.Multiplier(MAX_LEVEL + 5), PetPerks.Multiplier(MAX_LEVEL), "beyond the cap = the cap")
end)

test("GetPerk scales both numbers by the level multiplier, keeps rarity", function()
	for _, rarity in RarityTable.RARITY_ORDER do
		local base = (GameConstants.PET_PERKS :: any)[rarity]
		for level = 0, MAX_LEVEL do
			local perk = PetPerks.GetPerk(rarity, level)
			expect.ok(perk ~= nil, `{rarity} L{level} resolves`)
			local resolved = perk :: any
			local mult = 1 + PER_LEVEL * level
			expect.eq(resolved.rarity, rarity, `{rarity} L{level} rarity echoed`)
			expect.near(resolved.multiplier, mult, 1e-9, `{rarity} L{level} multiplier`)
			expect.near(resolved.maxHealth, base.maxHealth * mult, 1e-9, `{rarity} L{level} maxHealth`)
			expect.near(resolved.speedBonus, base.speedBonus * mult, 1e-9, `{rarity} L{level} speedBonus`)
		end
	end
	-- Mythical at the cap: 50 * 1.75 = 87.5 of record.
	expect.near((PetPerks.GetPerk("Mythical", MAX_LEVEL) :: any).maxHealth, 87.5, 1e-9, "Mythical L3 maxHealth")
end)

test("GetPerk on an unknown rarity is nil (fail safe, never fail loud)", function()
	expect.eq(PetPerks.GetPerk("Ultraweird", 1), nil, "unknown rarity")
	expect.eq(PetPerks.GetPerk("", 0), nil, "empty rarity")
end)

test("PET_TREATS economy rows: 249 R$ charm dev product, petUpgrade grant", function()
	local row = PriceLadder.GetRow("PET_TREATS") :: any
	expect.ok(row ~= nil, "PET_TREATS in the price ladder")
	expect.eq(row.priceRobux, 249, "price of record")
	expect.eq(row.priceRobux % 10, 9, "charm ending")
	expect.eq(row.type, "DevProduct", "consumable dev product")
	expect.eq(row.wiredInMvp, true, "wired in MVP")

	local productSpec = ProductCatalog.Get("PET_TREATS") :: any
	expect.ok(productSpec ~= nil, "PET_TREATS in the catalog")
	expect.eq(productSpec.isRandom, false, "deterministic: +1 level, public math")
	expect.eq(productSpec.grants.petUpgrade, true, "grants petUpgrade")
end)

return { name = "pet perks (equippable pets)", tests = tests }
