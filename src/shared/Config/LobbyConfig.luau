--!strict
-- CRYPTLINGS: NIGHT SHIFT — night-street lobby tunables of record (Lobby SOP).
-- Every SOP dimension, lighting value, budget cap, queue rule, and CTA copy
-- string lives here — no magic numbers inside the LobbyBuild builders, lobby
-- services, or lobby client controllers (SOP §9 "all tunables in one
-- LobbyConfig"; §12 step 1).
-- Pure Luau: requires no Roblox globals (lune-safe). Colors are frozen
-- { R, G, B } 0-255 tables (builders convert with Color3.fromRGB at apply
-- time); enum values are string names (builders index the Enum themselves).

local GameConstants = require("./GameConstants")

type RGB = { R: number, G: number, B: number }

local function rgb(r: number, g: number, b: number): RGB
	return table.freeze({ R = r, G = g, B = b })
end

return table.freeze({
	--------------------------------------------------------------------------
	-- Street corridor (SOP §1.1) — street axis = X, Factory at the east end
	--------------------------------------------------------------------------
	STREET_ASPHALT_WIDTH_STUDS = 38, -- two-lane night-street feel (§1.1: 36-40)
	SIDEWALK_WIDTH_STUDS = 9, -- each side (§1.1: 8-10)
	CORRIDOR_WIDTH_STUDS = 56, -- asphalt + 2 sidewalks = 38 + 2 * 9

	--------------------------------------------------------------------------
	-- Lots — 10 per side, 20 total (SOP §1.2; count of record stays
	-- GameConstants.HUB_DISPLAY_STATION_COUNT)
	--------------------------------------------------------------------------
	LOTS_PER_SIDE = 10,
	LOT_FRONTAGE_STUDS = 45,
	LOT_DEPTH_STUDS = 55,
	LOT_GAP_STUDS = 8, -- between adjacent lots
	LOT_PAD_RAISE_STUDS = 0.75, -- pad sits above sidewalk (§1.2: 0.5-1)

	--------------------------------------------------------------------------
	-- End plazas (SOP §1.3 / §1.4)
	--------------------------------------------------------------------------
	FACTORY_PLAZA_DEPTH_STUDS = 100, -- §1.3: 90-120
	COMING_SOON_FORECOURT_DEPTH_STUDS = 80, -- §1.4: 70-90

	--------------------------------------------------------------------------
	-- Mountain enclosure (SOP §1.5) — wedge stacks on the two long sides only
	--------------------------------------------------------------------------
	MOUNTAIN = table.freeze({
		WEDGE_BUDGET = 100, -- hard cap, both sides combined
		WIDTH_MIN_STUDS = 60,
		WIDTH_MAX_STUDS = 90,
		HEIGHT_MIN_STUDS = 50,
		HEIGHT_MAX_STUDS = 120,
		DEPTH_MIN_STUDS = 40,
		DEPTH_MAX_STUDS = 60,
		YAW_JITTER_DEGREES = 15, -- +/- Y-rotation per wedge
		COLOR_A = rgb(28, 30, 38), -- alternating slate tones
		COLOR_B = rgb(35, 38, 48),
		COLLISION_WALL_INSET_STUDS = 5, -- invisible wall this far inside the line
	}),

	--------------------------------------------------------------------------
	-- Lighting service values (SOP §2.1) — applied by LobbyBuild/LobbyLighting
	--------------------------------------------------------------------------
	LIGHTING = table.freeze({
		TECHNOLOGY = "ShadowMap", -- never Future (tanks low-end mobile)
		GLOBAL_SHADOWS = true,
		CLOCK_TIME = 17.6, -- sunset: low orange sun still casting light onto the street
		GEOGRAPHIC_LATITUDE = 30,
		BRIGHTNESS = 2.2, -- strong warm sunlight -> brighter sunlit street
		AMBIENT = rgb(72, 54, 48), -- warm dusk fill, never near-black grey
		OUTDOOR_AMBIENT = rgb(104, 72, 52), -- bright warm sunset bounce on the street
		EXPOSURE_COMPENSATION = 0.5,
	}),

	-- Atmosphere replaces legacy fog entirely (SOP §2.2 — FogEnd 220 would
	-- clip the ~700-stud street; LobbyLighting resets FogStart/FogEnd).
	ATMOSPHERE = table.freeze({
		DENSITY = 0.32,
		OFFSET = 0.25,
		COLOR = rgb(235, 138, 72), -- strong orange sunset haze
		DECAY = rgb(250, 116, 48), -- intense orange horizon glow toward the low sun
		HAZE = 2.2,
		GLARE = 0, -- no sun glow: the sun disc is hidden, avoid a blinding spot
	}),

	SKY = table.freeze({
		STAR_COUNT = 0, -- sunset, not night: no starfield
		MOON_ANGULAR_SIZE = 16,
		CELESTIAL_BODIES_SHOWN = false, -- hide the sun/moon disc (no blinding ball); sunlight still lights the street
	}),

	-- Post FX (SOP §2.4 — gate behind a device check if mobile testing drops)
	BLOOM = table.freeze({
		INTENSITY = 0.6,
		SIZE = 32,
		THRESHOLD = 0.85,
	}),
	COLOR_CORRECTION = table.freeze({
		CONTRAST = 0.18,
		SATURATION = 0.22,
		TINT = rgb(255, 228, 196), -- warm orange sunset tint
	}),

	--------------------------------------------------------------------------
	-- Street lamps (SOP §2.5) — SpotLight on a Neon bulb, Face=Bottom
	--------------------------------------------------------------------------
	STREET_LAMP = table.freeze({
		COUNT = 22, -- ~one per lot boundary, alternating sides (§2.5: 20-22)
		ANGLE = 110,
		RANGE = 50,
		BRIGHTNESS = 2.2,
		COLOR = rgb(255, 214, 170), -- SpotLight color
		BULB_COLOR = rgb(255, 220, 170), -- Neon bulb Part color
		SHADOWS = false, -- mandatory on every lobby light (SOP §10)
		STAGGER_STUDS = 45, -- alternating-side spacing along the street
		OFFSET_JITTER_STUDS = 3, -- +/- semi-random; never mirrored pairs
		MIN_POOL_SPACING_FACTOR = 0.9, -- spacing >= 0.9 * range so pools just kiss
	}),

	-- Per-lot podium wash: ONE SpotLight per lot, never one per podium
	-- (8 x 20 = 160 would blow the light budget — SOP §2.6).
	LOT_WASH = table.freeze({
		ANGLE = 120,
		RANGE = 35,
		BRIGHTNESS = 1.5,
	}),

	--------------------------------------------------------------------------
	-- Occupied-lot illumination (Addendum 1 Change 1) — claim/vacate is a
	-- property tween on the EXISTING per-lot wash SpotLight, never a runtime
	-- Light create/destroy (budget stays exactly 50). Claimed Angle 114 at the
	-- 18-stud mount = ~27.7-stud ground radius: reaches the 55-stud-axis lot
	-- edges, spills only into the 8-stud gap, never onto a neighbor; claimed
	-- reads by the 3.4x brightness contrast over vacant, not by bleed.
	--------------------------------------------------------------------------
	LOT_WASH_CLAIMED = table.freeze({
		ANGLE = 114,
		RANGE = 35,
		BRIGHTNESS = 2.4,
	}),
	LOT_WASH_VACANT = table.freeze({
		ANGLE = 120,
		RANGE = 35,
		BRIGHTNESS = 1.0,
		COLOR = rgb(255, 234, 210), -- warm-neutral; also the claimed-desaturation target
	}),
	-- Claimed wash color = owner accent lerped this fraction toward
	-- LOT_WASH_VACANT.COLOR (warm white) — tinted light, never a stage gel.
	LOT_WASH_ACCENT_DESATURATION = 0.4,

	-- Frozen 8-color owner accent palette (deterministic pick:
	-- LOT_OWNER_ACCENTS[userId % #LOT_OWNER_ACCENTS + 1]). All bright enough
	-- on Neon to clear BLOOM.THRESHOLD (0.85) or they will not read at night.
	LOT_OWNER_ACCENTS = table.freeze({
		rgb(255, 95, 95), -- coral red
		rgb(255, 165, 70), -- amber orange
		rgb(255, 230, 90), -- signal yellow
		rgb(120, 255, 140), -- mint green
		rgb(90, 235, 255), -- cyan
		rgb(120, 160, 255), -- cobalt blue
		rgb(200, 130, 255), -- violet
		rgb(255, 130, 220), -- magenta
	}),

	-- Neon perimeter trim framing the 45x55 lot pad edge (zero Light cost;
	-- claimed = opaque owner accent, vacant = gray at this transparency).
	LOT_TRIM = table.freeze({
		WIDTH = 1,
		THICK = 0.25,
		VACANT_TRANSPARENCY = 0.85,
	}),

	-- Overhead claimed-lot Neon beacon (height hard cap 35 — the 60-stud queue
	-- beacon must stay the tallest landmark) + owner nameplate billboard
	-- (vertical beams conventionally read VACANT in tycoons; the nameplate is
	-- the genre-inversion mitigation).
	LOT_BEACON = table.freeze({
		HEIGHT = 30,
		DIAMETER = 1.75,
		TRANSPARENCY = 0.8,
		FADE_DISTANCE = 150, -- client fades beacons beyond this camera distance
		FADE_TRANSPARENCY = 0.95, -- so 20 beacons never wall up the skyline
		CAP_DIAMETER = 2.5, -- Neon ball cap at the beacon top
		NAMEPLATE_HEIGHT = 12, -- BillboardGui mount height (studs)
		NAMEPLATE_MAX_DISTANCE = 120,
	}),

	LOT_TWEEN_SECONDS = 0.5, -- claim/vacate state tween (0.4-0.6 band), client-side

	-- <= 50 active local lights streamed in, all Shadows=false (SOP §2.6/§10);
	-- HubService asserts PartKit.LightBudget.Count() against this at build.
	LIGHT_BUDGET = 50,

	--------------------------------------------------------------------------
	-- Queue pad (SOP §6) — geometry/signage consumed by QueuePadBuilder and the
	-- QueuePadService metronome. The old QueueCore FSM timer keys (full-clamp,
	-- T-1 lock, re-arm, re-entry debounce, start-now hold, launch AFK slide)
	-- retired with QueueCore itself — the metronome rules of record live in
	-- DISPATCH below (Addendum 1 Change 6).
	--------------------------------------------------------------------------
	-- Re-export of the shift FSM's intermission length: the queue countdown
	-- and ShiftService can never diverge (single 45 s constant of record).
	QUEUE_SECONDS = GameConstants.INTERMISSION_SECONDS,
	QUEUE_CAPACITY = 4, -- roster cap regardless of bodies on the pad
	QUEUE_MIN_PLAYERS = 1, -- never gate on 2+ (retention killer at low CCU)
	QUEUE_MEMBERSHIP_HZ = 5, -- zone-volume poll rate (zone, never Touched)

	-- Pad geometry & signage (SOP §6.1)
	QUEUE_PAD_SIZE_STUDS = 14, -- dark 14 x 14 pad on the Factory plaza
	QUEUE_RING_WIDTH_STUDS = 1, -- Neon ring border
	QUEUE_ZONE_HEIGHT_STUDS = 6, -- invisible membership volume above the pad
	QUEUE_BEACON_HEIGHT_STUDS = 60, -- thin Neon pillar, seen from Coming Soon end
	QUEUE_BEACON_TRANSPARENCY = 0.7,
	QUEUE_BILLBOARD_HEIGHT_STUDS = 10, -- "CLOCK IN HERE" billboard above the pad
	QUEUE_RING_PULSE_TRANSPARENCY_MIN = 0.4, -- idle cyan pulse tween bounds
	QUEUE_RING_PULSE_TRANSPARENCY_MAX = 0.7,
	QUEUE_ARROW_BOUNCE_STUDS = 0.8, -- billboard arrow bounce (Sine, looped)
	QUEUE_ARROW_BOUNCE_SECONDS = 0.7,
	QUEUE_PAD_SPOT = table.freeze({ -- downward SpotLight pillar onto the pad
		ANGLE = 46,
		BRIGHTNESS = 3,
		RANGE = 22,
	}),

	-- Metronome dispatch (Addendum 1 Change 6) — constants of record for
	-- DispatchCore, the QueuePadService 45 s metronome, and the ShiftService
	-- slot pool. CYCLE_SECONDS re-exports the shift FSM's intermission length
	-- (== QUEUE_SECONDS — the single 45 s constant of record, never a literal).
	DISPATCH = table.freeze({
		CYCLE_SECONDS = GameConstants.INTERMISSION_SECONDS, -- == QUEUE_SECONDS (45)
		BIN_SIZE = 4, -- dispatch group cap (== QUEUE_CAPACITY)
		FREEZE_SECONDS = 3, -- T-3 snapshot freeze ("DOORS CLOSING"); late ENTRY defers
		AFK_EXCLUDE_SECONDS = 120, -- pad-idle this long -> excluded from snapshots
		INSHIFT_AFK_MOVE_STUDS = 10, -- moved less than this AND banked 0 crates...
		INSHIFT_AFK_WINDOW = 60, -- ...within the first this-many seconds -> auto-recall
		INSHIFT_STRIKES = 2, -- AFK strikes per server session that earn...
		PAD_COOLDOWN_SECONDS = 300, -- ...this pad cooldown (5 min)
		GROUP_IDLE_TEARDOWN_SECONDS = 90, -- whole group inactive -> early floor teardown
		SLOT_COUNT = 5, -- max concurrent shift sessions (20 players / 4)
		SLOT_PITCH_STUDS = 2000, -- origin pitch; exceeds streaming/light/audio range
		SLOT_BASE = table.freeze({ X = 1200, Y = 0, Z = 1200 }), -- slot-1 floor origin
	}),

	--------------------------------------------------------------------------
	-- Current Factory Brainrots wall (SOP §7; header text is exactly
	-- "Current Factory Brainrots" per Addendum 1 Change 7)
	--------------------------------------------------------------------------
	BRAINROT_WALL = table.freeze({
		WIDTH_STUDS = 48,
		HEIGHT_STUDS = 14,
		LIGHT_RANGE = 16, -- one SurfaceLight washes the wall
		LIGHT_BRIGHTNESS = 1,
		LIGHT_ANGLE = 60,
		MAX_VIEWPORT_CARDS = 24, -- beyond this, swap ViewportFrames for flats
	}),

	--------------------------------------------------------------------------
	-- Marquee block letters (SOP §8, §11.1) — 3D Neon Parts, color-coded
	--------------------------------------------------------------------------
	MARQUEE_COLORS = table.freeze({
		FACTORY = rgb(255, 120, 70), -- amber-red
		SHOP = rgb(90, 220, 255), -- cyan
		COMING_SOON = rgb(210, 210, 225), -- dim white + flicker
	}),
	MARQUEE_LETTER_HEIGHT_STUDS = 8, -- minimum; legible from half the street

	-- Coming Soon signage flicker (SOP §9): random interval, brief blink
	COMING_SOON_FLICKER = table.freeze({
		MIN_SECONDS = 3,
		MAX_SECONDS = 8,
		BLINK_SECONDS = 0.1, -- Neon <-> SmoothPlastic toggle duration
	}),

	--------------------------------------------------------------------------
	-- Sign & billboard readability (SOP §11.1) — the #1 night-sign bug is
	-- LightInfluence ~= 0; PartKit bakes these into every gui it makes
	--------------------------------------------------------------------------
	SURFACE_GUI = table.freeze({
		PIXELS_PER_STUD = 50,
		BRIGHTNESS = 2,
		LIGHT_INFLUENCE = 0,
	}),
	SIGN_TEXT_COLOR = rgb(255, 236, 200), -- warm white; never pure white at high Brightness
	BILLBOARD_MAX_DISTANCE = table.freeze({
		SIGN = 400, -- building/lot signs
		CLOCK_IN = 250, -- queue pad billboard
		PODIUM = 80, -- pet name labels (also the label cull distance)
	}),

	--------------------------------------------------------------------------
	-- Podium & display system (SOP §4.2, §4.5)
	--------------------------------------------------------------------------
	PODIUM = table.freeze({
		PLINTH_DIAMETER_STUDS = 3, -- cylinder plinth, SmoothPlastic dark gray
		PLINTH_HEIGHT_STUDS = 0.75,
		RING_HEIGHT_STUDS = 0.15, -- Neon rarity ring on top
		DISPLAY_PIVOT_HEIGHT_STUDS = 1.5, -- pet model pivot above the ring
		SPACING_STUDS = 5, -- minimum podium-to-podium spacing
	}),
	DISPLAY_SPIN_DEGREES_PER_SECOND = 20, -- client-side, ONE Heartbeat loop
	DISPLAY_BOB_AMPLITUDE_STUDS = 0.25,
	DISPLAY_BOB_PERIOD_SECONDS = 2, -- per-podium phase offset by slot index
	DISPLAY_ANIMATE_RADIUS_STUDS = 120, -- static beyond this camera distance
	RARITY_FX_RADIUS_STUDS = 50, -- sparkle/rainbow emitters enabled within this

	--------------------------------------------------------------------------
	-- Hero brainrot figures fronting the Factory (Addendum 1 Change 3) —
	-- rarity reads via Neon base ring + Highlight + sparkles; PointLights are
	-- forbidden (budget full at 50/50 — RarityFX.Apply runs the noLights path
	-- on heroes). Spin is client-side only; no bob ever on oversized figures.
	-- Figures are fully text-free — name duty lives on the Current Factory
	-- Brainrots wall (Addendum 2 R3-2; LABEL_* keys pruned with their sole
	-- consumer, the HeroFXController billboard subsystem).
	--------------------------------------------------------------------------
	HERO = table.freeze({
		SPIN_DEG_PER_SEC = 11, -- 10-12 band; half of DISPLAY_SPIN (20): monuments read slow
		PHASE_DEGREES = 120, -- per-hero phase offset so the 3 never sync
		RING_FOOTPRINT_FACTOR = 1.25, -- ring diameter = figure XZ footprint x this
		RING_HEIGHT = 0.5,
		RING_TRANSPARENCY = 0.25, -- between house halo 0.35 and god-ray 0.55
		SPARKLE_RATE = 10, -- 8-12 per hero; inherits the freed plaza particle budget
		SPARKLE_LIFETIME_MIN = 1.2,
		SPARKLE_LIFETIME_MAX = 2.0,
		SPARKLE_SPEED_MIN = 0.5,
		SPARKLE_SPEED_MAX = 1.5,
		HIGHLIGHT_OUTLINE_TRANSPARENCY = 0.15, -- outline-only (FillTransparency 1)
	}),

	--------------------------------------------------------------------------
	-- Swap-meet beacon (Addendum 1 Change 5) — andon convention: steady white
	-- = available, smooth 1.2 s green Sine pulse during an active trade
	-- (matches the house LEGENDARY pulse cadence, ~0.8 Hz, far under the WCAG
	-- 2.3.1 3-flash/s ceiling). Never hard-blink, strobe, or red. All tweens
	-- client-side off the server-set TradeActive attribute.
	--------------------------------------------------------------------------
	SWAP_BEACON = table.freeze({
		HEAD_HEIGHT = 13, -- Neon head height over the trade-pad midpoint (12-14 band)
		HEAD_SIZE = 2, -- 2x2x2 Neon sphere
		PILLAR_DIAMETER = 0.8,
		PILLAR_HEIGHT = 22, -- 20-25 band
		PILLAR_TRANSPARENCY = 0.55,
		IDLE_COLOR = rgb(255, 255, 255), -- steady full-bright white, no animation
		GREEN_DIM = rgb(40, 120, 60), -- active-trade pulse bounds...
		GREEN_BRIGHT = rgb(90, 255, 120),
		PULSE_SECONDS = 1.2, -- == house LEGENDARY_PULSE_SECONDS cadence
		TO_GREEN_SECONDS = 0.4, -- white -> green on trade start
		TO_WHITE_SECONDS = 0.6, -- back to white on complete/cancel/disconnect
	}),

	--------------------------------------------------------------------------
	-- Best Employees portrait board (Addendum 1 Change 2) — top 4 session
	-- crate collectors; rebuilt in the retired roster-board facade slot.
	--------------------------------------------------------------------------
	BEST_EMPLOYEES = table.freeze({
		BOARD_WIDTH = 10, -- board part studs (SurfaceGui at 50 px/stud)
		BOARD_HEIGHT = 6,
		CARD_COUNT = 4, -- always renders 4 cards (empty = "POSITION OPEN")
		DEBOUNCE_SECONDS = 0.25, -- dirty-flag coalesce for concurrent-floor banking bursts
		TOP_CARD_SCALE = 1.15, -- #1 card 15% larger
		THUMB = "rbxthumb://type=AvatarHeadShot&id=%d&w=150&h=150", -- string.format(THUMB, userId)
	}),

	--------------------------------------------------------------------------
	-- Housing CTA copy (SOP §5.4) — FALLBACK labels only, keyed by current
	-- housing tier. Live prices always come from MarketplaceService:
	-- GetProductInfo via MonetizationService.GetHousingCtaText; these strings
	-- render only when that lookup is unavailable. Verbatim per SOP.
	--------------------------------------------------------------------------
	HOUSING_CTA_FALLBACK = table.freeze({
		[0] = "Build House — 499 R$",
		[1] = "Upgrade to Two-Story — 499 R$",
		[2] = "Upgrade to Mansion — 1499 R$",
		-- tier 3 (mansion) has no next step: no CTA
	}),

	--------------------------------------------------------------------------
	-- House shell geometry (R5 — Addendum 4 §2.3, plan D3). Storey pitch is
	-- 10 (9 wall + 1 slab): clean 5+5 half-pitch stair flights and 9 studs of
	-- interior clear height. FFL1_BY_TIER is the floor-1 finished-floor height
	-- above the pad (T1 slab-on-pad 1; T2/T3 raised stoop 3); the ground slab
	-- is ONE plate of thickness == FFL1. floorTop(tier, floor) =
	-- FFL1_BY_TIER[tier] + (floor - 1) * FLOOR_PITCH_STUDS. HousePlan
	-- re-exports FLOOR_PITCH_STUDS — no other module re-literals these.
	--------------------------------------------------------------------------
	HOUSE = table.freeze({
		FLOOR_PITCH_STUDS = 10, -- WALL_HEIGHT_STUDS + SLAB_THICKNESS_STUDS
		WALL_HEIGHT_STUDS = 9,
		SLAB_THICKNESS_STUDS = 1,
		FFL1_BY_TIER = table.freeze({ 1, 3, 3 }), -- [tier] = floor-1 top above pad
	}),

	--------------------------------------------------------------------------
	-- House palette (R5 — Addendum 4 §1.0/§1.3, plan D8). Frozen { R, G, B }
	-- tables ONLY: builders/ghost convert with Color3.fromRGB at APPLY time —
	-- assigning a raw table to a Color3 property has crashed boot twice in
	-- past rounds; never construct Color3 here or in plan data. All Neon
	-- colors keep HSV Value >= 0.85 (max(R, G, B) >= 217, suite-pinned) so
	-- they clear BLOOM.THRESHOLD (0.85) and still read at night.
	--------------------------------------------------------------------------
	HOUSE_PALETTE = table.freeze({
		CHARCOAL = rgb(33, 33, 40), -- shell walls/slabs, matte
		SLATE = rgb(70, 72, 82), -- plinth band / trim, matte
		-- Tier identity Neon: [tier] = amber / cyan / magenta (Addendum 4 §1.0)
		TIER_IDENTITY = table.freeze({
			rgb(255, 190, 80), -- T1 amber
			rgb(120, 235, 255), -- T2 cyan
			rgb(255, 90, 220), -- T3 magenta
		}),
		GOLD = rgb(255, 215, 120), -- T3 entry accents (portico lintel, grand door)
		-- T3 per-floor interior accent Neon (cove + floor sign + handrail),
		-- warm -> cool with elevation as wayfinding (Addendum 4 §3):
		-- [1] F1 gold, [2] F2 amber, [3] F3 magenta, [4] F4 violet,
		-- [5] F5 ice-blue, [6] Roof warm white.
		T3_FLOOR_ACCENTS = table.freeze({
			rgb(255, 215, 120), -- F1 gold
			rgb(255, 190, 80), -- F2 amber
			rgb(255, 90, 220), -- F3 magenta
			rgb(200, 130, 255), -- F4 violet
			rgb(170, 230, 255), -- F5 ice-blue
			rgb(255, 240, 220), -- Roof warm white
		}),
		-- T3 window-panel gradient, [floor] 1..5: hue grades warm (gold, F1)
		-- to cool (ice/violet, F5) — pure color change, zero extra parts
		-- (Addendum 4 §1.3).
		T3_WINDOW_GRADIENT = table.freeze({
			rgb(255, 215, 120), -- F1 warm gold
			rgb(255, 185, 135), -- F2 peach
			rgb(245, 150, 200), -- F3 rose
			rgb(200, 150, 255), -- F4 violet
			rgb(170, 230, 255), -- F5 ice
		}),
	}),

	--------------------------------------------------------------------------
	-- Ghost preview & shop QOL (SOP §5.4, §8)
	--------------------------------------------------------------------------
	GHOST_PREVIEW_TRANSPARENCY = 0.45, -- §5.4: 40-50%, non-collidable
	GHOST_PREVIEW_RANGE_STUDS = 12, -- shown while standing at the lot sign
	SHOP_PROMPT_DISTANCE_STUDS = 10, -- counter ProximityPrompt activation
	SHOP_AUTOCLOSE_DISTANCE_STUDS = 15, -- UI auto-closes beyond this

	--------------------------------------------------------------------------
	-- Per-lot front step plate (Addendum 2 R3-3) — the single source of truth
	-- for BOTH the StreetBuilder plate geometry and the HousePreviewController
	-- stand-on-step predicate; neither side re-literals these numbers. World
	-- placement derives from the lot's slot-anchor CFrame on both sides
	-- (stationCFrame * CFrame.new(0, ·, LOCAL_Z)) so server and client share
	-- one transform. Border is Neon trim only — zero Light instances.
	-- R5 (plan D5): the plate DOES NOT MOVE — LOCAL_Z -29.5 stays of record;
	-- the apron strip z [-27.5, -23.5] holds only this plate's approach and
	-- the owner sign at (-16, -25), clear of collidable house parts at all tiers.
	--------------------------------------------------------------------------
	STEP_PLATE = table.freeze({
		-- Plate size: 6 W x 4 D x 0.35 H — wider than the 4-stud paving strip so
		-- it reads as a destination cap, not more path. Never below 4x4: that is
		-- the DynamicThumbstick floor (mobile users can't hold a sub-4-stud
		-- target).
		WIDTH = 6,
		DEPTH = 4,
		HEIGHT = 0.35,
		-- Top sits this proud of the lot pad top (PAD_TOP_Y 1.25 + 0.25 = 1.5):
		-- a literal step, walkable at base WalkSpeed.
		PROUD_STUDS = 0.25,
		-- -(LOT_DEPTH_STUDS / 2 + DEPTH / 2) = -(27.5 + 2). Plot-local frame,
		-- -Z streetward (same frame as HousePreviewController's SIGN_ANCHOR_Z).
		-- The 4-stud-deep plate spans local z -31.5..-27.5, so it sits fully
		-- street-side of the lot front line (-27.5) — the lot-interior veto can
		-- never fight the stand-on-plate predicate.
		LOCAL_Z = -29.5,
		BORDER_THICKNESS = 0.3, -- Neon trim strips framing the plate top perimeter
		BORDER_COLOR = rgb(140, 205, 255), -- == COLOR_GHOST hologram blue: step and ghost read as one system
		-- Hysteresis layer 1 (spatial): ENTER box = the exact plate half-extents;
		-- EXIT box = +1.5 studs all around. State only flips off outside the
		-- larger box, so thumbstick wobble at the plate edge cannot flicker the
		-- ghost.
		ENTER_HALF_X = 3.0,
		ENTER_HALF_Z = 2.0,
		EXIT_HALF_X = 4.5,
		EXIT_HALF_Z = 3.5,
		-- Vertical acceptance band for the HumanoidRootPart in plate-local space
		-- (HRP rides ~3 studs above the floor; band tolerates R15 scaling + the
		-- step lip). Jumping never counts: the predicate also requires
		-- FloorMaterial ~= Air.
		Y_BAND_MIN = 1,
		Y_BAND_MAX = 5,
		-- Hysteresis layer 2 (temporal): consecutive 0.1 s in-bounds polls before
		-- SHOW and out-of-bounds polls before HIDE (~0.2 s dwell filters the
		-- walk-across flash). Layer 3 — the lot-interior veto, hide IMMEDIATELY
		-- with no dwell and no exit margin — lives in the client predicate and
		-- overrides both layers.
		DWELL_POLLS = 2,
	}),

	--------------------------------------------------------------------------
	-- Lobby bicycle (Addendum 2 R3-5; ride pose + speed bump Addendum 3 R4-3)
	-- — zero Light instances: the night-street glow is ONE Neon strip only.
	-- The cosmetic greybox model is server-built by BikeService and welded to
	-- the HumanoidRootPart; every part Massless, CanCollide/CanQuery/CanTouch
	-- all false. The R4-3 ride pose is client-side Motor6D posing owned by
	-- the BikeRigPose controller (per-frame Stepped Transform writes, owning
	-- client bumps HipHeight); the weld-name topology contract (FrameWeld /
	-- SpinWeld legacy Welds + Handlebar/GlowStrip WeldConstraints) lives in
	-- BikeService. Speed is NOT here — it is GameConstants.BIKE_SPEED_MULT
	-- (2.2 → 30.8 studs/s, deliberately ABOVE the shift validator's 27; see
	-- the comment block of record there), folded into the two existing
	-- WalkSpeed owners off the server-set BikeActive attribute.
	--------------------------------------------------------------------------
	BIKE = table.freeze({
		LOBBY_RADIUS_STUDS = 400, -- mount gate: HRP within this of the hub spawn
		MODEL_LENGTH = 4, -- greybox bike bounds, studs (~2 x 1 x 4, 3-5 Parts)
		MODEL_HEIGHT = 1,
		MODEL_WIDTH = 2,
		NEON_STRIP_COLOR = rgb(255, 60, 180), -- saturated magenta, HSV V = 1.0: clears BLOOM.THRESHOLD and still reads with bloom off
		ENFORCE_SECONDS = 0.5, -- BikeService auto-dismount enforcement loop cadence
	}),

	--------------------------------------------------------------------------
	-- Plaza particles (SOP §9; fountain removed per Addendum 1 Change 8 — its
	-- freed jet/splash budget is banked here for hero sparkles & future FX)
	--------------------------------------------------------------------------
	PLAZA_PARTICLE_RATE_BUDGET = 100, -- combined emitter Rate near the plaza

	--------------------------------------------------------------------------
	-- Decor discipline (SOP §9, §11.3; static NPC dummies removed per
	-- Addendum 1 Change 8)
	--------------------------------------------------------------------------
	DECOR_SIDEWALK_CLEARANCE_STUDS = 4, -- props never block the walk line

	--------------------------------------------------------------------------
	-- Streaming (SOP §3.4, §10) — WP3.8 mirrors these into default.project.json
	--------------------------------------------------------------------------
	STREAMING_MIN_RADIUS = 128,
	STREAMING_TARGET_RADIUS = 640, -- ~4-6 lots per side in detail range
	STREAM_OUT_BEHAVIOR = "Opportunistic",

	--------------------------------------------------------------------------
	-- Part budgets (SOP §10, re-pinned by R5 — Addendum 4 §6, plan D4).
	-- The flat 400-part per-house shell cap key is DELETED: R5 budgets per
	-- tier instead, binding HousePlan.EstimateParts(tier) for the whole lot
	-- (shell + stair core + podiums + sign allowance).
	--------------------------------------------------------------------------
	PART_BUDGET_STREET_AND_LANDMARKS = 4000, -- street/factory/shop/wall/boundary/lamps/decor (3000 -> 4000, D4)
	PART_BUDGET_VACANT_LOT = 60, -- lot + sign + 8 podiums (unchanged)
	-- [tier] = whole-lot cap. T3 raise justified in Addendum 4 §6 (stair core
	-- + bulkhead + facade pass over 180 podium parts, est. ~396); T1/T2 drop
	-- below the old flat 400, partially offsetting.
	PART_BUDGET_HOUSE_BY_TIER = table.freeze({ 160, 240, 450 }),
	-- Worst case re-derived (D4): 20 lots x T3 cap 450 = 9,000 house parts
	-- + PART_BUDGET_STREET_AND_LANDMARKS 4,000 = 13,000 at caps; typical
	-- mixed-tier ~8-10k. 20,000 is the conservative end of mobile guidance
	-- (20-30k shown viable); the 15k -> 20k raise is recorded in the
	-- lobby_budget suite.
	PART_BUDGET_LOBBY_TOTAL = 20000,
})
