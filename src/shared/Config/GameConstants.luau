--!strict
-- CRYPTLINGS: NIGHT SHIFT — game constants of record (CONTRACTS v1 §G).
-- ALL tunable numbers live here — no magic numbers elsewhere in the codebase.
-- Pure Luau: requires no Roblox globals (lune-safe).

return table.freeze({
	--------------------------------------------------------------------------
	-- Shift / run loop (playtest tuning: fixed 4-minute shifts; SOP §1.2 spec
	-- of 8-12 minutes restores by raising these back to 480/720)
	--------------------------------------------------------------------------
	SHIFT_MIN_SECONDS = 120,
	SHIFT_MAX_SECONDS = 120, -- per-floor length = SHIFT_MIN_SECONDS + seededRandom() * (max - min)
	INTERMISSION_SECONDS = 45,
	-- §3.2: FloorGen must guarantee >=1 Tier1 case within 2 rooms of the dock
	TIME_TO_FIRST_CASE_SECONDS = 90,

	--------------------------------------------------------------------------
	-- Locker (free-open allowance; resets every LOCKER_RESET_WINDOW_SECONDS —
	-- the *_PER_DAY names predate the 4h window and mean "per window" now)
	--------------------------------------------------------------------------
	FREE_OPENS_PER_DAY = 30,
	VIP_OPENS_PER_DAY = 60,
	LOCKER_RESET_WINDOW_SECONDS = 4 * 3600, -- allowance window (was the unix day)
	SECONDS_PER_DAY = 86400,
	-- How often LockerService re-checks the unix-day boundary for online players
	-- (a minute of latency is invisible against a 24h timer).
	LOCKER_FLIP_POLL_SECONDS = 60,

	--------------------------------------------------------------------------
	-- Carrying
	--------------------------------------------------------------------------
	BASE_CARRY_SLOTS = 3,
	PASS_CARRY_BONUS = 2, -- PASS_CARRY game pass

	--------------------------------------------------------------------------
	-- Noise model (§G): the greed dial
	--------------------------------------------------------------------------
	NOISE_PER_CARRIED_CASE = 0.18, -- added to noise01 per carried case while moving
	SQUIRM_INTERVAL_MIN_SECONDS = 8, -- each carried case squirms every random 8-15s
	SQUIRM_INTERVAL_MAX_SECONDS = 15,
	SQUIRM_LOUDNESS_PER_TIER = 0.35, -- squirm loudness = 0.35 * case tier, at holder position
	SPRINT_LOUDNESS_MULT = 2.0, -- sprint multiplies all emitted loudness
	STILL_LOUDNESS_MULT = 0.25, -- standing still
	CASE_NOISE_MULT_DEFAULT = 1.0, -- per-player; scent spray sets 0 for current run
	-- Defect hearing: reacts when loudness * max(0, 1 - distance / HEARING_RANGE_MAX) > threshold
	DEFECT_HEARING_THRESHOLD = 0.08,
	HEARING_RANGE_MAX = 150,
	-- Two hits to go down (100 HP / 50): the first hit is the warning shot —
	-- the Defect backs off (post-attack ignore) and you run or you die.
	DEFECT_ATTACK_DAMAGE = 50,

	--------------------------------------------------------------------------
	-- Combat (fight-for-the-box): attacks only land on a player carrying a
	-- COMBAT_RARE_CASE_TIER case; weapons are limited-use paid consumables.
	-- Reaching 0 HP downs the target (ShiftService.DownPlayer scatters their
	-- carried cases — the fight is FOR the boxes).
	--------------------------------------------------------------------------
	COMBAT_RARE_CASE_TIER = 3,
	COMBAT_SHOVE_DAMAGE = 10,
	COMBAT_SWORD_DAMAGE = 25,
	COMBAT_PAINTBALL_DAMAGE = 15,
	COMBAT_GUN_DAMAGE = 40,
	COMBAT_MELEE_RANGE_STUDS = 9,
	COMBAT_GUN_RANGE_STUDS = 30,
	COMBAT_COOLDOWN_SECONDS = 1.5,
	COMBAT_KNOCKBACK_SPEED = 40, -- studs/s impulse away from the attacker

	--------------------------------------------------------------------------
	-- Golden case: super-rare glowing world spawn; opens as a Tier 3 case
	--------------------------------------------------------------------------
	GOLDEN_CASE_CHANCE = 0.02, -- per world case spawned on the floor

	--------------------------------------------------------------------------
	-- Rainbow box (tier 4): hue-cycling jackpot crate, Legendary+ only inside
	--------------------------------------------------------------------------
	RAINBOW_CASE_CHANCE = 0.01, -- per shift: ~1 in 100 floors spawns exactly one

	--------------------------------------------------------------------------
	-- Mega crate: ~1 in 10,000 shifts. Giant glowing-purple crate that GUARANTEES
	-- a Mythical when opened. Grabbing it drops every other carried box and locks
	-- the carrier out of picking up any more boxes for the rest of that shift.
	--------------------------------------------------------------------------
	MEGA_CASE_CHANCE = 0.0001,

	--------------------------------------------------------------------------
	-- Floor-spawn cartoon weapons: free pickups, better than the bare-hand
	-- shove (10 dmg) but capped WELL below the paid ladder (paintball 15 /
	-- sword 25 / zap blaster 40) so paid stays strictly better.
	--------------------------------------------------------------------------
	FLOOR_WEAPON_SPAWNS = 3, -- pickups scattered per shift floor
	COMBAT_BOXING_DAMAGE = 12,
	COMBAT_NUNCHUCK_DAMAGE = 14,
	FLOOR_WEAPON_BOXING_CHARGES = 10,
	FLOOR_WEAPON_NUNCHUCK_CHARGES = 8,

	--------------------------------------------------------------------------
	-- Lobby leaderboard (collection points per owned cryptling, by rarity)
	--------------------------------------------------------------------------
	LEADERBOARD_POINTS = table.freeze({
		Common = 1,
		Uncommon = 3,
		Rare = 10,
		Epic = 25,
		Legendary = 100,
		Godly = 250,
		Mythical = 1000,
	}),
	LEADERBOARD_REFRESH_SECONDS = 15,
	LEADERBOARD_MAX_ROWS = 10,

	--------------------------------------------------------------------------
	-- Movement
	--------------------------------------------------------------------------
	WALKSPEED_BASE = 14,
	SPRINT_SPEED = 20,
	CARRY_SPEED_MULT_PER_CASE = 0.94,
	-- Lobby bike multiplier (Addendum 3 R4-3): 14 * 2.2 = 30.8 studs/s — above
	-- SPRINT_SPEED (20) so mounting is worth it, and DELIBERATELY ABOVE the
	-- shift speed-validator cap SPRINT_SPEED * 1.35 = 27. Intentional and
	-- safe: the validator walks shift-floor participants only (lobby players
	-- are unvalidated) and the bike is force-dismounted pre-pivot on shift
	-- start, so BikeActive is structurally false wherever the cap applies.
	-- Any future "validate the lobby too" change MUST add a BikeActive
	-- allowance ≈ WALKSPEED_BASE * BIKE_SPEED_MULT * 1.15 ≈ 35, or riders
	-- insta-flag. Genre band for ride mounts is 1.5x–2x; 2.2 is deliberately
	-- punchy but under the ~2.5 "reads as exploit-speed" threshold. Never
	-- stacks with sprint: precedence is max(bike path, sprint path) in both
	-- formulas. Read by BOTH WalkSpeed owners — server
	-- CaseService.ApplyCarrySpeed and client InputController.applyWalkSpeed —
	-- off the server-set BikeActive attribute; never a third WalkSpeed writer
	-- (PetPerks line 8 rule).
	BIKE_SPEED_MULT = 2.2,

	--------------------------------------------------------------------------
	-- Interaction ranges (shared: client contextual targeting AND server
	-- validation read these — promoting them here keeps the two from diverging)
	--------------------------------------------------------------------------
	PICKUP_RANGE_STUDS = 10, -- grab a world case / a downed teammate's case
	REVIVE_RANGE_STUDS = 6, -- revive hold must start and stay within this

	--------------------------------------------------------------------------
	-- Downed / revive
	--------------------------------------------------------------------------
	DOWNED_BLEEDOUT_SECONDS = 45,
	REVIVE_HOLD_SECONDS = 4,

	--------------------------------------------------------------------------
	-- Shift pay (x2 with PASS_2X_PAY)
	--------------------------------------------------------------------------
	SHIFT_PAY_PER_CASE_TIER = 5, -- 5 * case tier per banked case
	SHIFT_PAY_EXTRACTION_BONUS = 10,

	--------------------------------------------------------------------------
	-- Floor generation (greybox)
	--------------------------------------------------------------------------
	FLOOR_GRID_CELLS = 6, -- 6x6 grid
	FLOOR_CELL_SIZE_STUDS = 36,
	PART_BUDGET_FLOOR = 3000,
	PART_BUDGET_SHELF_ROOM = 400,
	STREAMING_ENABLED = true,

	--------------------------------------------------------------------------
	-- Hub: SOP night-street lobby (lobby SOP §1; built by HubService at Init
	-- from the LobbyBuild/* builder modules). One straight street corridor —
	-- 38-stud asphalt + 9-stud sidewalks — runs Factory (east end: clock-in
	-- queue pad, Brainrot wall, lockers, fountain plaza) to the COMING SOON
	-- tower (west end), with 20 player lots (10 per side, 45x55) between them,
	-- mountain-wedge enclosure and street lamps per SOP §1.5/§2.5. Detailed
	-- dimensions/lighting/budgets live in Shared.Config.LobbyConfig.
	--------------------------------------------------------------------------
	HUB_ORIGIN = table.freeze({ X = -2000, Y = 0, Z = 0 }), -- far from the shift floors
	PART_BUDGET_HUB = 3000, -- SOP §10 street + landmarks cap (lots budgeted per PART_BUDGET_LOT)
	HUB_LOCKER_COUNT = 20, -- locker bank size (one per player; lobby caps at 20)
	HUB_DISPLAY_STATION_COUNT = 20, -- vacant lots in every lobby (one per player)

	--------------------------------------------------------------------------
	-- Player lots & housing tiers (ShelfService slot tiers, slot ids "s1"..;
	-- ShelfRoomBuilder builds the lot structure per tier). Tier 0 is the
	-- starter lot: 8 ground podiums. Robux housing upgrades (HOUSING_* dev
	-- products) raise profile.housing.tier permanently.
	--   tier 0 starter lot   ->  8 displays (ground podiums)
	--   tier 1 House         -> 12 displays (inside the house)
	--   tier 2 2-Story House -> 24 displays (12 per story, walkable stairs)
	--   tier 3 Mansion       -> 60 displays (5 floors x 12, walkable stairs)
	--------------------------------------------------------------------------
	SHELF_BASE_SLOTS = 8, -- tier 0 starter lot (kept name: many consumers)
	HOUSING_TIER_SLOTS = table.freeze({ 12, 24, 60 }), -- [tier] = slots for tiers 1..3
	HOUSING_MAX_TIER = 3,
	HOUSING_MAX_SLOTS = 60,
	PART_BUDGET_LOT = 1200, -- per-lot budget (mansion + 60 displays, warn-only)

	--------------------------------------------------------------------------
	-- First-shift onboarding (SOP §3.2: beats inside the player's REAL first
	-- shift, no tutorial screens; timings owned by OnboardingService)
	--------------------------------------------------------------------------
	ONBOARDING_FOREMAN_LINE_AT_SECONDS = 3, -- ClockIn -> ForemanLine
	ONBOARDING_FIRST_CASE_AT_SECONDS = 10, -- spec: FirstCase at t+10s
	ONBOARDING_FLYBY_AT_SECONDS = 60, -- spec: flyby at t+~60s (after first pickup)
	ONBOARDING_FLYBY_TO_EXTRACTION_SECONDS = 5, -- let the flyby read before redirecting
	ONBOARDING_BEAT_FAILSAFE_SECONDS = 120, -- hard failsafe advances any stuck beat

	--------------------------------------------------------------------------
	-- R7 Fix #1: first-ever WELCOME panel (KID-FRIENDLY copy of record).
	-- Short, friendly, one idea per line. The headless onboarding_copy suite
	-- asserts these exist and are non-empty. Inside the frozen literal.
	--------------------------------------------------------------------------
	WELCOME = table.freeze({
		TITLE = "WELCOME!",
		FACTORY = "Go to the FACTORY to start your job.",
		BRAINROTS = "Grab boxes. They hold cute BRAINROTS!",
		LOCKER = "Your boxes go in your LOCKER.",
		PETS = "Open a box to get a PET.",
		PODIUM = "Put your favorite PET on a PODIUM.",
		HOUSE = "Earn coins to make your HOUSE bigger.",
		DISMISS = "GOT IT!",
	}),
	WELCOME_SHOW_DELAY_SECONDS = 0.4, -- after spawn, before the panel fades in

	--------------------------------------------------------------------------
	-- R7 Fix #2: empty-state clock-in reminders (KID-FRIENDLY). Each string
	-- keeps the literal word FACTORY (test asserts it). CLOCK_IN_REMINDER is a
	-- toast (<=40 chars). The *_EMPTY labels are the in-sheet copy.
	--------------------------------------------------------------------------
	EMPTY_STATE = table.freeze({
		CLOCK_IN_REMINDER = "Clock in at the FACTORY to get boxes!", -- toast, <=40 chars
		LOCKER_EMPTY = "No boxes yet!\nClock in at the FACTORY to get some.",
		PETS_EMPTY = "No pets yet!\nGet boxes at the FACTORY, then open them.",
		PODIUM_EMPTY = "Nothing here yet!\nGet a pet at the FACTORY to show it off.",
	}),

	--------------------------------------------------------------------------
	-- R7 Fix #4: starter-case guide subtitles (KID-FRIENDLY, one action each).
	-- Drives the chained welcome -> guide client step machine.
	--------------------------------------------------------------------------
	STARTER_GUIDE = table.freeze({
		OPEN_CASE = "Tap your box to open it!", -- R9: box is now earned, dropped "free"
		PLACE_PODIUM = "Now put your pet on a PODIUM!",
		EQUIP_PET = "Open the PETS tab (bottom-left) and tap EQUIP!",
		CLOCK_IN = "Now go clock in at the FACTORY!",
		PODIUM_MARKER = "Put your pet here!", -- world billboard on the empty podium pad
		CLOCK_IN_MARKER = "CLOCK IN HERE", -- world billboard at the factory clock-in zone
		LOT_ARRIVAL = "This is YOUR lot!", -- R8: landing cue after the TeleportToLot pivot
		CLOCK_ARRIVAL = "Clock in to start your shift!", -- R8: landing cue after TeleportToClockIn
	}),

	--------------------------------------------------------------------------
	-- R9 (intro floor): brand-new-account intro floor copy + tuning. KID-SIMPLE,
	-- one idea at a time, no jargon, no em-dashes. The intro runner FIRES IntroBeat
	-- steps and the intro guide UI CONSUMES this copy. The chaser is un-loseable
	-- by design (slower than the player's exempt walk speed).
	--------------------------------------------------------------------------
	INTRO = table.freeze({
		GRAB_FIRST = "Grab the glowing box!",
		GRAB_MORE = "Grab one more box!",
		CHASE_TELEGRAPH = "Uh oh! Time to run!",
		RUN_TO_EXIT = "Run to the green door!",
		BUMP_NUDGE = "Keep going! You can make it!",
		STUCK_HINT = "Walk to the big green light!",
		REACHED_EXIT = "You made it! Great job!",
		EXIT_MARKER = "WAY OUT",
		BOX_MARKER = "GRAB!",
		BOXES_NEEDED = 2,
		BOX_COUNT = 3, -- boxes spawned on the floor (>= BOXES_NEEDED, a couple-plus)
		PICKUP_RADIUS = 13, -- studs; server proximity pickup (measured on the flat XZ plane)
		STUCK_HINT_SECONDS = 6,
		EXIT_DWELL_SECONDS = 1.5,
		CHASER_SPEED = 11, -- a true sub-walk speed (WALKSPEED_BASE is 14) so the kid always pulls ahead
		CHASER_SPAWN_DISTANCE = 28, -- studs behind the player (away from the exit) when the chase begins
	}),

	--------------------------------------------------------------------------
	-- Mobile hard gates (SOP §3.2; tested weekly on a $150 Android)
	--------------------------------------------------------------------------
	MOBILE_MIN_FPS = 30,
	MOBILE_MAX_JOIN_SECONDS = 45, -- defer floor gen until after first spawn into hub
	MOBILE_MIN_TOUCH_TARGET_PX = 44,
	SERVER_MEMORY_BUDGET_MB = 2048,

	--------------------------------------------------------------------------
	-- Trading (Stage 4 swap meet — SOP §3.1 ④, §3.3, §8.2). Server (TradeService)
	-- and client (TradeUI) both read these so the FSM and its UI mirrors never
	-- diverge (promoted from TradeService locals at Stage 4 integration).
	--------------------------------------------------------------------------
	TRADE_INVITE_RANGE_STUDS = 30, -- spec: target <=30 studs (or both on TradePads)
	TRADE_INVITE_RATE_LIMIT = 5, -- spec: 5 invites/min
	TRADE_INVITE_RATE_WINDOW_SECONDS = 60,
	TRADE_CONFIRM_STAGE2_DELAY_SECONDS = 3, -- §3.3: stage 2 only >=3s after both stage 1
	TRADE_INVITE_EXPIRY_SECONDS = 30, -- server: pending invite the target never engaged with
	TRADE_INVITE_UI_TIMEOUT_SECONDS = 20, -- client: invite card drain (< server expiry)
	TRADE_SESSION_IDLE_TIMEOUT_SECONDS = 300, -- zombie-session guard
	TRADE_MAX_OFFER_CASES = 20,
	TRADE_MAX_OFFER_CRYPTLING_KINDS = 24,
	TRADE_MAX_OFFER_CRYPTLING_COUNT = 99,
	TRADE_HISTORY_MAX = 30, -- profile.tradeHistory ring size (contract §D)

	--------------------------------------------------------------------------
	-- Consumables (Stage 6 — SOP §4.2; ConsumableService validation and the
	-- ConsumableHUD chip pulse both read the key range, so it lives here to
	-- keep server and client from diverging)
	--------------------------------------------------------------------------
	VAULT_KEY_RANGE_STUDS = 8, -- Foreman's Key usable within this of the VaultDoor
	VAULT_DOOR_OPEN_SECONDS = 1.4, -- vault door slide-open tween
	-- The key's bonus vault case tier — also its §8.1 odds-disclosure tier
	-- (ComplianceService catalog + StarterPackUI both read this).
	VAULT_CASE_TIER = 4,

	--------------------------------------------------------------------------
	-- Monetization & social (§4.3, §3.2)
	--------------------------------------------------------------------------
	STARTER_PACK_OFFER_SECONDS = 86400, -- 24h visible timer
	STARTER_PACK_POLL_SECONDS = 5, -- secondExtractionAt trigger-watch cadence
	FRIEND_INVITE_REWARD_OPENS = 1, -- extraOpenCredits per rewarded invite
	FRIEND_INVITE_MAX_REWARDED = 5, -- max distinct friends
	-- How long the invite-reward path waits for an online inviter's profile to
	-- session-lock before giving up quietly (they almost always loaded long ago).
	INVITER_LOAD_TIMEOUT_SECONDS = 10,
	TOYLINE_SEASON_SECONDS = 6 * 7 * 86400, -- 6-week toy-line season
	-- Fixed toy-line season-grid anchor: 2026-01-01T00:00:00Z (a unix-day
	-- boundary). Boundaries fall at anchor + k * TOYLINE_SEASON_SECONDS on every
	-- server forever (§5.4 live-ops calendar reads this one value of record).
	-- Changing it mid-line moves the countdown for every player — it is a
	-- versioned constant, deliberately NOT an economy flag.
	TOYLINE_EPOCH_ANCHOR = 1767225600,

	--------------------------------------------------------------------------
	-- Equippable pets (PetService + PetUI). One OWNED cryptling follows the
	-- player in-world (server-built greybox from its RarityTable recipe).
	--------------------------------------------------------------------------
	PET_SCALE = 0.55, -- recipe size/offset multiplier vs the unboxing render
	PET_FOLLOW_RIGHT_STUDS = 2.6, -- follow point: right of the character root...
	PET_FOLLOW_BACK_STUDS = 2.6, -- ...and behind it (root-local +X / +Z)
	PET_FOLLOW_RESPONSIVENESS = 6, -- 1/s exponential smoothing toward the point
	PET_TELEPORT_DISTANCE_STUDS = 60, -- snap (no lerp) when left this far behind
	PET_BOB_AMPLITUDE_STUDS = 0.2, -- idle hover bob
	PET_BOB_CYCLES_PER_SECOND = 1.1,

	-- Pet upgrade: each level multiplies every perk number by
	-- (1 + PET_UPGRADE_PERK_MULT_PER_LEVEL * level), capped at MAX_LEVEL.
	PET_UPGRADE_MAX_LEVEL = 3,
	PET_UPGRADE_PERK_MULT_PER_LEVEL = 0.25,

	-- Shift-pay cost to buy the NEXT pet level (index = current level + 1): the
	-- first upgrade is cheap, each one after is much pricier. The 249 R$
	-- PET_TREATS dev product remains a Robux alternative to all of these.
	PET_UPGRADE_PAY_COSTS = table.freeze({ 50, 300, 1200 }),

	-- Rarity-scaled pet perks — the rarer the pet, the bigger the boost across
	-- every dimension. Which dimension(s) a given pet actually grants is set by
	-- its perk KIND (Shared.Logic.PetPerks.PERK_KIND_BY_ID); inactive dimensions
	-- are zeroed for that pet. Dimensions:
	--   * maxHealth   — additive Humanoid.MaxHealth (PetService, server-owned).
	--   * speedBonus  — additive WalkSpeed studs/s (both WalkSpeed owners read the
	--     "PetSpeedBonus" attribute: client InputController + server CaseService).
	--   * pvpStrength — outgoing PVP damage multiplier bonus ("PetPvpStrength"
	--     attribute; CombatService scales damage dealt by 1 + this).
	--   * carryBonus  — extra carry slots ("PetCarryBonus" attribute; CaseService
	--     .GetMaxCarry adds floor(this) — stack more boxes per run).
	PET_PERKS = table.freeze({
		Common = table.freeze({ maxHealth = 5, speedBonus = 1, pvpStrength = 0.05, carryBonus = 1 }),
		Uncommon = table.freeze({ maxHealth = 8, speedBonus = 1.5, pvpStrength = 0.1, carryBonus = 1 }),
		Rare = table.freeze({ maxHealth = 12, speedBonus = 2, pvpStrength = 0.15, carryBonus = 2 }),
		Epic = table.freeze({ maxHealth = 18, speedBonus = 2.5, pvpStrength = 0.22, carryBonus = 2 }),
		Legendary = table.freeze({ maxHealth = 25, speedBonus = 3, pvpStrength = 0.3, carryBonus = 3 }),
		Godly = table.freeze({ maxHealth = 35, speedBonus = 4, pvpStrength = 0.4, carryBonus = 4 }),
		Mythical = table.freeze({ maxHealth = 50, speedBonus = 5, pvpStrength = 0.5, carryBonus = 5 }),
	}),
})
