--!strict
-- CRYPTLINGS: NIGHT SHIFT — pure pet-perk math (equippable pet feature).
-- The single perk calculator: PetService (server, applies Humanoid.MaxHealth +
-- the advisory "PetSpeedBonus" attribute) and PetUI (client, perk copy) both
-- call this so the applied numbers and the displayed numbers can never diverge.
--
-- Perk model of record (see GameConstants.PET_PERKS doc): maxHealth is the
-- SHIPPED perk; speedBonus is advisory-only (WalkSpeed already has two owners —
-- InputController.applyWalkSpeed and CaseService.ApplyCarrySpeed — that
-- recompute it wholesale, so an additive server write would just be clobbered).
--
-- Pure Luau: requires no Roblox globals (lune-safe; tests/suites/pet_perks).

local GameConstants = require("../Config/GameConstants")

local PetPerks = {}

export type Perk = {
	rarity: string,
	maxHealth: number, -- additive Humanoid.MaxHealth bonus, upgrade-scaled
	speedBonus: number, -- additive WalkSpeed bonus, upgrade-scaled
	pvpStrength: number, -- outgoing PVP damage multiplier bonus, upgrade-scaled
	carryBonus: number, -- extra carry slots (floored on use), upgrade-scaled
	kind: string, -- which dimension(s) are active for this pet ("hp".."all")
	multiplier: number, -- the upgrade multiplier that produced the numbers
}

-- Perk KIND -> active dimension set. Pets pick a kind for variety; the rarity
-- still sets the magnitude (rarer = stronger), and inactive dims are zeroed.
PetPerks.PERK_KINDS = table.freeze({
	hp = table.freeze({ maxHealth = true }),
	speed = table.freeze({ speedBonus = true }),
	pvp = table.freeze({ pvpStrength = true }),
	carry = table.freeze({ carryBonus = true }),
	hp_pvp = table.freeze({ maxHealth = true, pvpStrength = true }),
	hp_carry = table.freeze({ maxHealth = true, carryBonus = true }),
	speed_pvp = table.freeze({ speedBonus = true, pvpStrength = true }),
	speed_carry = table.freeze({ speedBonus = true, carryBonus = true }),
	all = table.freeze({ maxHealth = true, speedBonus = true, pvpStrength = true, carryBonus = true }),
}) :: { [string]: { [string]: boolean } }

-- Per-pet kind of record (by cryptling id). Unmapped ids default to "hp".
PetPerks.PERK_KIND_BY_ID = table.freeze({
	-- Common
	smudge = "hp",
	lintball = "carry",
	crumb = "speed",
	poppo = "speed",
	gloop = "hp",
	-- Uncommon
	wonk = "pvp",
	drips = "hp",
	stitches = "pvp",
	mopps = "carry",
	tapey = "carry",
	honku = "speed",
	-- Rare
	sploot = "hp",
	glitch = "speed",
	furnace = "pvp",
	boxo = "carry",
	sproing = "speed",
	-- Epic
	inkblot = "pvp",
	vacuumo = "carry",
	conveyo = "speed_carry",
	misprint_trophy = "hp",
	-- Legendary
	prototype_zero = "hp_pvp",
	forklift = "hp_carry",
	-- Godly
	foreman_prime = "hp_pvp",
	static_king = "speed_pvp",
	-- Mythical
	polychrome = "all",
}) :: { [string]: string }

function PetPerks.KindForId(id: any): string
	local kind = if type(id) == "string" then PetPerks.PERK_KIND_BY_ID[id] else nil
	return if type(kind) == "string" then kind else "hp"
end

-- Sanitizes a stored/claimed upgrade level into 0..PET_UPGRADE_MAX_LEVEL
-- (floors fractions, rejects junk to 0).
function PetPerks.ClampLevel(level: any): number
	if type(level) ~= "number" or level ~= level then
		return 0
	end
	return math.clamp(math.floor(level), 0, GameConstants.PET_UPGRADE_MAX_LEVEL)
end

-- Upgrade multiplier: (1 + PET_UPGRADE_PERK_MULT_PER_LEVEL * level), level
-- clamped. Level 0 = 1x (no PET_TREATS bought yet).
function PetPerks.Multiplier(level: any): number
	return 1 + GameConstants.PET_UPGRADE_PERK_MULT_PER_LEVEL * PetPerks.ClampLevel(level)
end

type PerkRow = { maxHealth: number, speedBonus: number, pvpStrength: number, carryBonus: number }

-- Full rarity perk (ALL dimensions at this rarity's magnitude) at one upgrade
-- level, or nil for an unknown rarity (callers treat nil as "no perk" — fail
-- safe, never fail loud). Per-pet zeroing happens in GetPerkForId.
function PetPerks.GetPerk(rarity: string, level: any): Perk?
	local base = (GameConstants.PET_PERKS :: { [string]: PerkRow })[rarity]
	if base == nil then
		return nil
	end
	local multiplier = PetPerks.Multiplier(level)
	return {
		rarity = rarity,
		maxHealth = base.maxHealth * multiplier,
		speedBonus = base.speedBonus * multiplier,
		pvpStrength = base.pvpStrength * multiplier,
		carryBonus = base.carryBonus * multiplier,
		kind = "all",
		multiplier = multiplier,
	}
end

-- Resolved perk for a SPECIFIC pet (by id): the rarity magnitude with only the
-- pet's kind's dimensions kept (the rest zeroed). This is what PetService
-- applies and PetUI displays.
function PetPerks.GetPerkForId(rarity: string, level: any, id: any): Perk?
	local full = PetPerks.GetPerk(rarity, level)
	if full == nil then
		return nil
	end
	local kindName = PetPerks.KindForId(id)
	local active = PetPerks.PERK_KINDS[kindName] or PetPerks.PERK_KINDS.hp
	return {
		rarity = full.rarity,
		maxHealth = if active.maxHealth then full.maxHealth else 0,
		speedBonus = if active.speedBonus then full.speedBonus else 0,
		pvpStrength = if active.pvpStrength then full.pvpStrength else 0,
		carryBonus = if active.carryBonus then full.carryBonus else 0,
		kind = kindName,
		multiplier = full.multiplier,
	}
end

return table.freeze(PetPerks)
