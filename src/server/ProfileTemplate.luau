--!strict
-- CRYPTLINGS: NIGHT SHIFT — PlayerData_v1 profile template (CONTRACTS v1 §D).
-- ProfileService deep-copies this for new players and :Reconcile() fills any
-- missing keys for returning players — only ADD fields, never repurpose them.
-- Bump schemaVersion (and write a migration in PlayerDataService) for breaking
-- changes. Data rules: no Instances, no userdata, no mixed/gapped tables.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Types"))

local template: Types.ProfileData = {
	schemaVersion = 1,
	shiftPay = 0,

	-- Unix day (math.floor(os.time() / 86400)) this player was last seen.
	-- Maintained by PlayerDataService on load; drives the CoreLoop step-5
	-- "d1_return" funnel (§H). Nobody else writes it.
	lastSeenDay = 0,

	-- {[cryptlingId]: count} — unboxed + tradeable
	collection = {},

	locker = {
		cases = {}, -- array<Types.CaseStub>
		freeOpensUsed = 0,
		lastResetDay = 0, -- unix day = math.floor(os.time() / 86400)
		extraOpenCredits = 0,
	},

	shelf = {
		slots = {}, -- {[slotId]: cryptlingId}
	},

	-- Lot housing tier (HOUSING_* upgrades): 0 starter lot | 1 House |
	-- 2 2-Story House | 3 Mansion. Reconcile fills 0 on pre-housing profiles.
	housing = {
		tier = 0,
	},

	stats = {
		shifts = 0,
		extractions = 0,
		deaths = 0,
		casesBanked = 0,
		rarePulls = 0,
		firstShiftDone = false,
		secondExtractionAt = 0, -- unix time; drives the Starter Pack offer (§4.3)
	},

	consumables = {
		scentSpray = 0,
		reviveBeacon = 0,
		foremansKey = 0,
		exitWarp = 0, -- EXIT_WARP product: 1 mid-run teleport to the dock per buy
		swordSwings = 0, -- WEAPON_SWORD charges (consumed per hit landed)
		gunShots = 0, -- WEAPON_GUN charges (consumed per shot)
		paintballShots = 0, -- WEAPON_PAINTBALL charges (cheaper, weaker ranged)
		boxingGloveSwings = 0, -- FREE floor pickup (cartoon melee, below paid)
		nunchuckSwings = 0, -- FREE floor pickup (cartoon melee, below paid)
	},

	monetization = {
		starterPackOwned = false,
		starterPackOfferAt = 0,
		processedReceipts = {}, -- ring buffer, last 50 receiptIds
		passCache = {}, -- {[passSku]: true}
	},

	social = {
		invitesRewarded = {}, -- {[userIdStr]: true}, cap 5 (FRIEND_INVITE_MAX_REWARDED)
	},

	-- Equippable pet (PetService). Reconcile fills this on pre-pet profiles.
	pets = {
		equippedId = "", -- cryptlingId followed in-world; "" = none equipped
		upgradeLevel = 0, -- 0..PET_UPGRADE_MAX_LEVEL (PET_TREATS purchases)
	},

	-- R7 (Fix #1 + Fix #4): unified first-ever onboarding flow. SEPARATE from
	-- stats.firstShiftDone so the welcome panel + starter-case guide coexist with
	-- the in-shift OnboardingBeat. Reconcile fills these false on existing profiles
	-- on next load (one-time-flag pattern, like firstShiftDone). Only ever ADD.
	onboarding = {
		welcomeShown = false, -- welcome panel shown once-ever
		starterCaseGranted = false, -- guaranteed-rare starter case granted (idempotent)
		starterGuideDone = false, -- client step machine finished (optional tracking)
		-- R9 (intro floor): one-time flags for the brand-new-account intro floor.
		-- introFloorDone flips true once the player LEAVES the intro floor (success
		-- OR graceful-failure fallthrough); introBoxesBanked flips true only when the
		-- intro actually banked the collected boxes (drives the substitution).
		introFloorDone = false,
		introBoxesBanked = false,
	},

	-- last 30: {tradeId, partnerId, gave = {cases, cryptlings}, got = {cases, cryptlings}, at}
	-- Full trade records additionally go to DataStore "TradeLedger_v1" key=tradeId
	-- for rollback (§3.3, §8.1) — written by the trading stage, not here.
	tradeHistory = {},
}

return template
