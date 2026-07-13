--!strict
-- CRYPTLINGS: NIGHT SHIFT — shared type contracts (CONTRACTS v1 §C, §D).
-- Single source of truth. Later stages consume these types, never redefine them.
-- Pure Luau: requires no Roblox globals (lune-safe).

local Types = {}

--------------------------------------------------------------------------------
-- Cases & locker (§C)
--------------------------------------------------------------------------------

export type CaseSource = "run" | "bundle" | "key" | "code"

export type CaseStub = {
	uid: string, -- HttpService:GenerateGUID(false)
	tier: number, -- 1..6 (6 = rainbow box)
	lineId: string, -- "line1" for Toy Line 1
	acquiredAt: number, -- unix time
	source: CaseSource,
	mega: boolean?, -- mega crate: guarantees a Mythical when opened (reconcile-safe)
	-- R7 (Fix #4): guaranteed-rarity starter case. When set to a RarityName
	-- (e.g. "Rare"), UnboxService forces a uniform pick from that rarity pool
	-- (mirrors the mega-Mythical guarantee) WITHOUT the mega grab-lock. Normal
	-- cases never set this, so TIER_WEIGHTS and the disclosed odds are untouched.
	guaranteedRarity: string?, -- additive, reconcile-safe
}

export type LockerState = {
	cases: { CaseStub },
	freeOpensRemaining: number,
	extraOpenCredits: number,
	opensPerDay: number,
	nextResetAt: number, -- unix time of next unix-day boundary (00:00 UTC)
}

--------------------------------------------------------------------------------
-- Trading (§C)
--------------------------------------------------------------------------------

export type TradeOffer = {
	offerCaseUids: { string },
	offerCryptlings: { [string]: number }, -- cryptlingId -> count
	confirmStage: number, -- 0 | 1 | 2
}

export type TradeState = {
	tradeId: string,
	players: { [string]: TradeOffer }, -- key = tostring(userId)
	valueWarning: boolean,
	-- Additive optional extensions (Stage 4 integration; TradeUI consumes all
	-- three defensively, so older payloads without them remain valid):
	caseTiers: { [string]: number }?, -- {[caseUid]: tier} for every offered case, both sides
	values: { [string]: number }?, -- {[userIdStr]: ValueIndex offer value} (absent if ValueIndex is)
	valueWarningFor: string?, -- userIdStr the warning is AGAINST (the higher-value giver)
}

export type TradeRecord = {
	tradeId: string,
	partnerId: number,
	gave: { cases: { string }, cryptlings: { [string]: number } },
	got: { cases: { string }, cryptlings: { [string]: number } },
	at: number,
}

--------------------------------------------------------------------------------
-- Shop (§C)
--------------------------------------------------------------------------------

export type OddsRow = { rarity: string, pct: number }

export type CatalogEntry = {
	sku: string,
	displayName: string,
	priceRobux: number,
	kind: "DevProduct" | "GamePass",
	isRandom: boolean,
	odds: { OddsRow }?, -- §8.1: must match GetOddsTable exactly
	bonusPct: number?,
	owned: boolean?,
	-- Additive (Stage 6 integration): the Roblox dev-product/game-pass id the
	-- client prompts MarketplaceService with. 0/absent = not live yet (Creator
	-- Dashboard id not filled in) — ShopUI refuses to prompt and shows a toast.
	assetId: number?,
	-- Additive (LOBBY_SOP §5.4): GetProductInfo-live Robux price, attached to
	-- housing entries (rows with requiresHousingTier) via MonetizationService's
	-- 5-min cache. Absent when the product isn't live yet or the lookup failed —
	-- clients fall back to priceRobux (the PriceLadder price).
	livePriceRobux: number?,
}

--------------------------------------------------------------------------------
-- Rarity / Cryptling definitions (§E)
--------------------------------------------------------------------------------

export type RarityName = "Common" | "Uncommon" | "Rare" | "Epic" | "Legendary" | "Godly" | "Mythical"

-- Greybox render spec for unboxing reveals and shelf displays.
-- size is Vector3 and offset is CFrame when running under Roblox; plain frozen
-- tables ({X,Y,Z} / {X,Y,Z,RX,RY,RZ} degrees) when required headless by lune.
export type RecipePart = {
	shape: "Block" | "Ball" | "Cylinder" | "Wedge",
	size: any,
	offset: any,
	colorOverride: any?, -- Color3? under Roblox, {R,G,B} 0-255 headless
}

export type CryptlingDef = {
	id: string,
	name: string,
	rarity: RarityName,
	color: any, -- rarity color (Color3 under Roblox)
	recipe: { RecipePart }, -- 4-12 parts, ordered
	notInPool: boolean?, -- true => never rolled (e.g. misprint_trophy)
	tradeable: boolean?, -- defaults true; false for misprint_trophy
	-- Collectible redesign (all optional, additive):
	epithet: string?, -- flavor sub-line on name cards / showcase labels
	scale: number?, -- render scale multiplier (default 1) honored by all renderers
	fx: { string }?, -- reserved per-def FX tags for RarityFX (none authored yet)
}

--------------------------------------------------------------------------------
-- Profile schema (§D) — ProfileService store "PlayerData_v1", key "p_"..userId
--------------------------------------------------------------------------------

export type ProfileData = {
	schemaVersion: number,
	shiftPay: number,
	-- Unix day (math.floor(os.time() / 86400)) the player was last seen.
	-- Maintained by PlayerDataService on load; drives the CoreLoop step-5
	-- "d1_return" funnel (§H). Contract-D amendment, Stage 0.
	lastSeenDay: number,
	collection: { [string]: number }, -- {[cryptlingId]: count} unboxed + tradeable
	locker: {
		cases: { CaseStub },
		freeOpensUsed: number,
		lastResetDay: number, -- unix day = math.floor(os.time() / 86400)
		extraOpenCredits: number,
	},
	shelf: {
		slots: { [string]: string }, -- {[slotId]: cryptlingId}
	},
	-- Lot housing tier (HOUSING_* dev products; reconcile-safe addition).
	-- 0 starter lot (8 podiums) | 1 House (12) | 2 2-Story (24) | 3 Mansion (60).
	housing: {
		tier: number,
	},
	stats: {
		shifts: number,
		extractions: number,
		deaths: number,
		casesBanked: number,
		rarePulls: number,
		firstShiftDone: boolean,
		secondExtractionAt: number,
	},
	consumables: {
		scentSpray: number,
		reviveBeacon: number,
		foremansKey: number,
		exitWarp: number, -- EXIT_WARP product: 1 mid-run teleport to the dock per buy
		swordSwings: number, -- WEAPON_SWORD charges (consumed per hit landed)
		gunShots: number, -- WEAPON_GUN charges (consumed per shot)
		paintballShots: number, -- WEAPON_PAINTBALL charges (cheaper, weaker ranged)
		boxingGloveSwings: number, -- FREE floor pickup (cartoon melee, below paid)
		nunchuckSwings: number, -- FREE floor pickup (cartoon melee, below paid)
	},
	monetization: {
		starterPackOwned: boolean,
		starterPackOfferAt: number,
		processedReceipts: { string }, -- ring buffer, last 50 receiptIds
		passCache: { [string]: boolean },
	},
	social: {
		invitesRewarded: { [string]: boolean }, -- {[userIdStr]: true}, cap 5
	},
	-- Equippable pet (PetService). Reconcile-safe addition: only ever ADD fields.
	pets: {
		equippedId: string, -- cryptlingId followed in-world; "" = none equipped
		upgradeLevel: number, -- 0..PET_UPGRADE_MAX_LEVEL (PET_TREATS purchases)
	},
	-- R7 (Fix #1 + Fix #4): unified first-ever onboarding flow. SEPARATE from
	-- stats.firstShiftDone (the in-shift OnboardingBeat gate) so the two systems
	-- coexist. welcomeShown gates the welcome panel (once-ever); starterCaseGranted
	-- makes the guaranteed-rare starter case grant idempotent; starterGuideDone is
	-- optional completion tracking for the client step machine. Reconcile-safe.
	onboarding: {
		welcomeShown: boolean,
		starterCaseGranted: boolean,
		starterGuideDone: boolean,
		-- R9 (intro floor): one-time flags. introFloorDone => the player has LEFT the
		-- intro floor (success or graceful fallthrough); introBoxesBanked => the intro
		-- actually banked collected boxes. Reconcile-safe additive booleans.
		introFloorDone: boolean,
		introBoxesBanked: boolean,
	},
	tradeHistory: { TradeRecord }, -- last 30
}

return Types
