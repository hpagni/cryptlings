--!strict
-- CRYPTLINGS: NIGHT SHIFT — Toy Line 1 "Factory Floor Misfits" (CONTRACTS v1 §E).
-- 24 Cryptlings: 5 common / 6 uncommon / 5 rare / 3 epic / 2 legendary /
-- 2 godly / 1 mythical, plus the non-pool misprint_trophy (Starter Pack
-- exclusive shelf item, §4.2). Legendary holds the old Godly slot (red, same
-- rates); Godly is the new 10x-rarer gold chase tier; Mythical is rainbow at
-- a flat 1-in-100,000.
--
-- ALL rolls happen server-side in UnboxService only. This module is pure logic:
-- it requires no Roblox globals, so lune can run tests/rarity-sim.luau headless.
-- Under Roblox, size/offset/color are real Vector3/CFrame/Color3 values; headless
-- they fall back to plain frozen tables with the same data.

--------------------------------------------------------------------------------
-- Guarded datatype constructors (Roblox <-> pure-Luau)
--------------------------------------------------------------------------------

local RobloxVector3: any = Vector3 :: any
local RobloxCFrame: any = CFrame :: any
local RobloxColor3: any = Color3 :: any

local function v3(x: number, y: number, z: number): any
	if RobloxVector3 ~= nil then
		return RobloxVector3.new(x, y, z)
	end
	return table.freeze({ X = x, Y = y, Z = z })
end

-- Position plus optional rotation in degrees.
local function cf(x: number, y: number, z: number, rx: number?, ry: number?, rz: number?): any
	local rxd, ryd, rzd = rx or 0, ry or 0, rz or 0
	if RobloxCFrame ~= nil then
		return RobloxCFrame.new(x, y, z) * RobloxCFrame.Angles(math.rad(rxd), math.rad(ryd), math.rad(rzd))
	end
	return table.freeze({ X = x, Y = y, Z = z, RX = rxd, RY = ryd, RZ = rzd })
end

local function rgb(r: number, g: number, b: number): any
	if RobloxColor3 ~= nil then
		return RobloxColor3.fromRGB(r, g, b)
	end
	return table.freeze({ R = r, G = g, B = b })
end

local function part(shape: string, size: any, offset: any, colorOverride: any?)
	return table.freeze({
		shape = shape,
		size = size,
		offset = offset,
		colorOverride = colorOverride,
	})
end

--------------------------------------------------------------------------------
-- Rarities (order matters: roll cumulation and UI ordering both use it)
--------------------------------------------------------------------------------

local RARITY_ORDER = table.freeze({ "Common", "Uncommon", "Rare", "Epic", "Legendary", "Godly", "Mythical" })

-- Tier display copy (collectible redesign): how each rarity NAME renders on
-- name cards, banners and odds rows. Low tiers stay sentence-case; the chase
-- tiers shout. Pure data — safe for lune and the client alike.
local RARITY_DISPLAY = table.freeze({
	Common = "Common",
	Uncommon = "Uncommon",
	Rare = "Rare",
	Epic = "Epic",
	Legendary = "LEGENDARY",
	Godly = "GODLY",
	Mythical = "『MYTHICAL』",
})

-- Tier flavor epithets (factory-floor lore one-liners shown as sub-copy where
-- a label has room).
local RARITY_EPITHETS = table.freeze({
	Common = "Standard Issue",
	Uncommon = "Slightly Defective",
	Rare = "Quality Hold",
	Epic = "Containment Bin",
	Legendary = "Recall Order",
	Godly = "Management",
	Mythical = "It Got Out",
})

-- Greybox + UI colors, used everywhere a rarity is shown (§E).
-- Legendary = red (took over the old Godly slot); Godly stays gold (now far
-- rarer, new roster); Mythical is RAINBOW in-world (per-part recipe colors) —
-- this single UI color is its nameplate magenta.
local RARITY_COLORS = table.freeze({
	Common = rgb(178, 178, 178),
	Uncommon = rgb(85, 170, 85),
	Rare = rgb(60, 120, 216),
	Epic = rgb(140, 80, 200),
	Legendary = rgb(230, 60, 50),
	Godly = rgb(235, 190, 52),
	Mythical = rgb(255, 80, 220),
})

-- Integer weights out of 1,000,000 (scaled from the old /10000 so Mythical's
-- 1-in-100,000 — weight 10 — is expressible). Disclosed percentages are EXACT
-- (weight / 10000). Tier 2 is the BASELINE shown on the hub odds board and on
-- all purchased cases. Tiers 4/5 are deep-floor spawns; tier 6 is the
-- RAINBOW BOX: Legendary-and-up only.
-- Legendary inherited the old Godly rates verbatim; Godly is 10x rarer than
-- that; Mythical is a flat 1/100,000 in every regular tier.
local WEIGHT_TOTAL = 1000000
local BASELINE_TIER = 2
local TIER_WEIGHTS: { [number]: { [string]: number } } = table.freeze({
	[1] = table.freeze({
		Common = 649890,
		Uncommon = 270000,
		Rare = 70000,
		Epic = 9000,
		Legendary = 1000,
		Godly = 100,
		Mythical = 10,
	}),
	[2] = table.freeze({
		Common = 499490,
		Uncommon = 300000,
		Rare = 150000,
		Epic = 45000,
		Legendary = 5000,
		Godly = 500,
		Mythical = 10,
	}),
	[3] = table.freeze({
		Common = 298490,
		Uncommon = 350000,
		Rare = 250000,
		Epic = 85000,
		Legendary = 15000,
		Godly = 1500,
		Mythical = 10,
	}),
	[4] = table.freeze({ -- deep floor: distance-weighted spawns only
		Common = 150990,
		Uncommon = 330000,
		Rare = 320000,
		Epic = 150000,
		Legendary = 40000,
		Godly = 9000,
		Mythical = 10,
	}),
	[5] = table.freeze({ -- the "not every game" crate
		Common = 50000,
		Uncommon = 200000,
		Rare = 350000,
		Epic = 280000,
		Legendary = 100000,
		Godly = 19990,
		Mythical = 10,
	}),
	[6] = table.freeze({ -- rainbow box: Legendary and above ONLY
		Common = 0,
		Uncommon = 0,
		Rare = 0,
		Epic = 0,
		Legendary = 900000,
		Godly = 99000,
		Mythical = 1000,
	}),
})

--------------------------------------------------------------------------------
-- Helper colors for recipes
--------------------------------------------------------------------------------

local WHITE = rgb(245, 245, 245)
local DARK = rgb(30, 30, 30)
local INK = rgb(35, 25, 45) -- Blotto's living-ink body
local GHOST_CYAN = rgb(120, 220, 255) -- Glitcherino's chromatic-aberration halves
local GHOST_MAGENTA = rgb(255, 120, 220)

--------------------------------------------------------------------------------
-- Roster — recipe is THE render spec for unboxing reveals and shelf displays.
-- 4-12 greybox parts each; ugly-cute misprint silhouettes. Offsets are relative
-- to the Cryptling root (ground at Y=0); parts default to the rarity color
-- unless colorOverride is set. Optional per-def fields (collectible redesign):
--   epithet: string  -- flavor sub-line on name cards / showcase labels
--   scale: number    -- render scale multiplier, default 1 (size AND offset
--                       translation; all three renderers honor it)
--------------------------------------------------------------------------------

local CRYPTLINGS = table.freeze({
	-- COMMONS ------------------------------------------------------------
	table.freeze({
		id = "smudge",
		name = "Smudgini", -- brainrot pass: chantable display names, ids stay forever
		rarity = "Common",
		epithet = "QC Failure #001",
		scale = 0.6,
		color = RARITY_COLORS.Common,
		recipe = table.freeze({
			-- Squished cat loaf: chunky body slab, round head, stubby tail.
			part("Block", v3(2, 1.2, 2.4), cf(0, 0.6, 0.2)),
			part("Ball", v3(1.6, 1.6, 1.6), cf(0, 1.3, -0.9)),
			-- Mismatched ears (one came off the press way too small).
			part("Wedge", v3(0.5, 0.5, 0.4), cf(-0.55, 2.1, -0.9)),
			part("Wedge", v3(0.22, 0.22, 0.3), cf(0.55, 2, -0.9)),
			-- Big googly eyes, deliberately not the same size.
			part("Ball", v3(0.55, 0.55, 0.55), cf(-0.35, 1.45, -1.55), WHITE),
			part("Ball", v3(0.42, 0.42, 0.42), cf(0.35, 1.4, -1.55), WHITE),
			part("Ball", v3(0.26, 0.26, 0.26), cf(-0.35, 1.45, -1.78), DARK),
			part("Ball", v3(0.2, 0.2, 0.2), cf(0.35, 1.4, -1.74), DARK),
			-- The smudge itself: a dark thumbprint disc smeared on its flank.
			part("Cylinder", v3(0.1, 0.9, 0.9), cf(1, 0.8, 0.4), rgb(55, 52, 58)),
			part("Ball", v3(0.6, 0.6, 0.6), cf(0, 0.85, 1.5)),
		}),
	}),
	table.freeze({
		id = "lintball",
		name = "Lint Lord",
		rarity = "Common",
		epithet = "Found Behind the Dryer",
		scale = 0.6,
		color = RARITY_COLORS.Common,
		recipe = table.freeze({
			-- Fat lint hamster: one big fuzzball body with stubby cheek ears.
			part("Ball", v3(2.4, 2.4, 2.4), cf(0, 1.2, 0)),
			part("Ball", v3(0.5, 0.5, 0.5), cf(-0.7, 2.3, -0.4)),
			part("Ball", v3(0.5, 0.5, 0.5), cf(0.7, 2.3, -0.4)),
			-- Googly eyes (left one rolled bigger off the line).
			part("Ball", v3(0.5, 0.5, 0.5), cf(-0.45, 1.5, -1.05), WHITE),
			part("Ball", v3(0.4, 0.4, 0.4), cf(0.45, 1.45, -1.05), WHITE),
			part("Ball", v3(0.26, 0.26, 0.26), cf(-0.45, 1.5, -1.26), DARK),
			part("Ball", v3(0.2, 0.2, 0.2), cf(0.45, 1.45, -1.22), DARK),
			-- Buck tooth + tiny feet poking out from under the fluff.
			part("Wedge", v3(0.35, 0.4, 0.25), cf(0, 0.95, -1.15, 180, 0, 0), WHITE),
			part("Ball", v3(0.5, 0.5, 0.5), cf(-0.5, 0.25, -0.8)),
			part("Ball", v3(0.5, 0.5, 0.5), cf(0.5, 0.25, -0.8)),
			-- The gag: a stray sock from the dryer, worn proudly as a hat.
			part("Block", v3(0.9, 0.6, 0.6), cf(0.5, 2.55, 0, 0, 0, -25), rgb(120, 120, 130)),
		}),
	}),
	table.freeze({
		id = "crumb",
		name = "Crumbus", -- display rename only; the id stays "crumb" forever
		rarity = "Common",
		epithet = "Do Not Eat",
		scale = 0.6,
		color = RARITY_COLORS.Common,
		recipe = table.freeze({
			-- Bread-loaf pigeon: loaf body, bobblehead, tail wedge.
			part("Block", v3(1.8, 1.4, 2.2), cf(0, 1, 0.1)),
			part("Ball", v3(1.1, 1.1, 1.1), cf(0, 1.9, -1)),
			part("Wedge", v3(0.8, 0.5, 0.7), cf(0, 1.2, 1.3)),
			-- Beak + mismatched googly eyes.
			part("Wedge", v3(0.35, 0.3, 0.5), cf(0, 1.85, -1.7, 0, 180, 0), rgb(220, 160, 70)),
			part("Ball", v3(0.42, 0.42, 0.42), cf(-0.32, 2.1, -1.4), WHITE),
			part("Ball", v3(0.34, 0.34, 0.34), cf(0.32, 2.05, -1.4), WHITE),
			part("Ball", v3(0.2, 0.2, 0.2), cf(-0.32, 2.1, -1.58), DARK),
			part("Ball", v3(0.16, 0.16, 0.16), cf(0.32, 2.05, -1.55), DARK),
			-- Stick legs, plus the gag: somebody already took a bite out of its back.
			part("Cylinder", v3(0.7, 0.18, 0.18), cf(-0.4, 0.35, 0.3, 0, 0, 90), rgb(150, 120, 80)),
			part("Cylinder", v3(0.7, 0.18, 0.18), cf(0.4, 0.35, 0.3, 0, 0, 90), rgb(150, 120, 80)),
			part("Wedge", v3(0.7, 0.6, 0.7), cf(0.6, 1.6, 0.85, 0, -35, 0), rgb(110, 110, 110)),
		}),
	}),
	table.freeze({
		id = "poppo",
		name = "Poppo Bubblini",
		rarity = "Common",
		epithet = "Do Not Pop (Somebody Popped)",
		scale = 0.6,
		color = RARITY_COLORS.Common,
		recipe = table.freeze({
			-- Bubble-wrap pufferfish: one round body studded with packing bubbles.
			part("Ball", v3(2.2, 2.2, 2.2), cf(0, 1.1, 0)),
			part("Ball", v3(0.5, 0.5, 0.5), cf(-0.75, 1.7, -0.45), rgb(225, 235, 245)),
			part("Ball", v3(0.5, 0.5, 0.5), cf(0.7, 1.85, 0.25), rgb(225, 235, 245)),
			part("Ball", v3(0.5, 0.5, 0.5), cf(0, 2.1, 0.45), rgb(225, 235, 245)),
			-- The gag: one bubble on its flank is already popped flat. Who did it.
			part("Cylinder", v3(0.1, 0.55, 0.55), cf(1.05, 1.1, -0.4), rgb(160, 170, 180)),
			-- Mismatched googly eyes.
			part("Ball", v3(0.5, 0.5, 0.5), cf(-0.35, 1.45, -1), WHITE),
			part("Ball", v3(0.4, 0.4, 0.4), cf(0.35, 1.4, -1), WHITE),
			part("Ball", v3(0.24, 0.24, 0.24), cf(-0.35, 1.45, -1.22), DARK),
			part("Ball", v3(0.18, 0.18, 0.18), cf(0.35, 1.4, -1.17), DARK),
			-- Stubby side fins + tail so it reads fish, not packing material.
			part("Wedge", v3(0.2, 0.6, 0.7), cf(-1.15, 1.2, 0.2, 0, 0, 30)),
			part("Wedge", v3(0.2, 0.6, 0.7), cf(1.15, 1.2, 0.2, 0, 0, -30)),
			part("Wedge", v3(0.5, 0.7, 0.6), cf(0, 1.15, 1.35, 0, 180, 0)),
		}),
	}),
	table.freeze({
		id = "gloop",
		name = "Gloopini Snailoni",
		rarity = "Common",
		epithet = "Non-Toxic, Probably",
		scale = 0.6,
		color = RARITY_COLORS.Common,
		recipe = table.freeze({
			-- Glue snail: low slug slab with a round face up front.
			part("Block", v3(1.1, 0.7, 2.4), cf(0, 0.35, 0.1)),
			part("Ball", v3(1, 1, 1), cf(0, 0.85, -1)),
			-- Eye stalks with mismatched googly eyes on top.
			part("Cylinder", v3(0.7, 0.16, 0.16), cf(-0.3, 1.5, -1, 0, 0, 90)),
			part("Cylinder", v3(0.7, 0.16, 0.16), cf(0.3, 1.4, -1, 0, 0, 90)),
			part("Ball", v3(0.42, 0.42, 0.42), cf(-0.3, 1.95, -1.05), WHITE),
			part("Ball", v3(0.34, 0.34, 0.34), cf(0.3, 1.8, -1.05), WHITE),
			part("Ball", v3(0.2, 0.2, 0.2), cf(-0.3, 1.95, -1.23), DARK),
			part("Ball", v3(0.16, 0.16, 0.16), cf(0.3, 1.8, -1.19), DARK),
			-- The gag: its shell is a glue bottle, orange twist nozzle and all.
			part("Block", v3(1, 1.5, 0.95), cf(0, 1.45, 0.6), WHITE),
			part("Cylinder", v3(0.55, 0.32, 0.32), cf(0, 2.45, 0.6, 0, 0, 90), rgb(235, 130, 50)),
			-- It leaks: a glue puddle trails off its back end.
			part("Cylinder", v3(0.12, 1.4, 1.4), cf(0, 0.06, 1.7, 0, 0, 90), WHITE),
		}),
	}),
	-- UNCOMMONS ----------------------------------------------------------
	table.freeze({
		id = "wonk",
		name = "Wonkarini",
		rarity = "Uncommon",
		epithet = "Assembled on a Friday",
		scale = 0.8,
		color = RARITY_COLORS.Uncommon,
		recipe = table.freeze({
			-- Squat frog body with two eye stalks on top.
			part("Block", v3(2.4, 1.5, 1.9), cf(0, 0.9, 0)),
			part("Ball", v3(0.85, 0.85, 0.85), cf(-0.85, 1.9, -0.5)),
			part("Ball", v3(0.85, 0.85, 0.85), cf(0.85, 1.95, -0.5)),
			-- The gag: googly eyes physically aimed in opposite directions.
			part("Ball", v3(0.65, 0.65, 0.65), cf(-1.1, 2, -0.75), WHITE),
			part("Ball", v3(0.55, 0.55, 0.55), cf(1.1, 2.05, -0.75), WHITE),
			part("Ball", v3(0.3, 0.3, 0.3), cf(-1.38, 2.05, -0.85), DARK),
			part("Ball", v3(0.26, 0.26, 0.26), cf(1.36, 2, -0.85), DARK),
			-- Big flat mouth line + splayed flipper feet.
			part("Block", v3(1.4, 0.12, 0.12), cf(0, 0.7, -0.96), rgb(60, 120, 60)),
			part("Wedge", v3(0.8, 0.3, 0.9), cf(-1.2, 0.15, -0.6, 0, 35, 0)),
			part("Wedge", v3(0.8, 0.3, 0.9), cf(1.2, 0.15, -0.6, 0, -35, 0)),
		}),
	}),
	table.freeze({
		id = "drips",
		name = "Drippini",
		rarity = "Uncommon",
		epithet = "Certified Drippy",
		scale = 0.8,
		color = RARITY_COLORS.Uncommon,
		recipe = table.freeze({
			-- The gag: it stands in its own melt puddle.
			part("Cylinder", v3(0.15, 2.6, 2.6), cf(0, 0.08, 0, 0, 0, 90), rgb(70, 140, 70)),
			part("Ball", v3(0.45, 0.45, 0.45), cf(0.95, 0.25, -0.5), rgb(70, 140, 70)),
			-- Pear penguin body sagging sideways, white belly disc on the front.
			part("Ball", v3(2, 2, 2), cf(0, 1.1, 0)),
			part("Ball", v3(1.4, 1.4, 1.4), cf(0.15, 2.25, 0)),
			part("Cylinder", v3(0.12, 1.3, 1.3), cf(0, 1.05, -0.92, 0, 90, 0), WHITE),
			-- Beak + drooping mismatched googly eyes.
			part("Wedge", v3(0.3, 0.25, 0.45), cf(0.15, 2.15, -0.85, 0, 180, 0), rgb(240, 170, 60)),
			part("Ball", v3(0.42, 0.42, 0.42), cf(-0.18, 2.5, -0.6), WHITE),
			part("Ball", v3(0.34, 0.34, 0.34), cf(0.5, 2.4, -0.58), WHITE),
			part("Ball", v3(0.2, 0.2, 0.2), cf(-0.18, 2.5, -0.78), DARK),
			part("Ball", v3(0.16, 0.16, 0.16), cf(0.5, 2.4, -0.73), DARK),
			-- Flipper wedges mid-slump.
			part("Wedge", v3(0.25, 1.1, 0.6), cf(-1.05, 1.2, 0, 0, 0, 35)),
			part("Wedge", v3(0.25, 1.1, 0.6), cf(1.05, 1.15, 0, 0, 0, -35)),
		}),
	}),
	table.freeze({
		id = "stitches",
		name = "Stitchetti",
		rarity = "Uncommon",
		epithet = "Held Together, Barely",
		scale = 0.8,
		color = RARITY_COLORS.Uncommon,
		recipe = table.freeze({
			-- Roly-poly teddy: ball belly, ball head, round ears, stubby arms.
			part("Ball", v3(1.9, 1.9, 1.9), cf(0, 0.95, 0)),
			part("Ball", v3(1.5, 1.5, 1.5), cf(0, 2.2, 0)),
			part("Ball", v3(0.6, 0.6, 0.6), cf(-0.6, 3, 0)),
			part("Ball", v3(0.6, 0.6, 0.6), cf(0.6, 3, 0)),
			part("Ball", v3(0.55, 0.55, 0.55), cf(-1, 1.2, -0.3)),
			part("Ball", v3(0.55, 0.55, 0.55), cf(1, 1.2, -0.3)),
			-- The gag: a replacement button eye, way bigger than the real one.
			part("Ball", v3(0.5, 0.5, 0.5), cf(-0.3, 2.3, -0.62), DARK),
			part("Ball", v3(0.32, 0.32, 0.32), cf(0.35, 2.35, -0.68), WHITE),
			part("Ball", v3(0.16, 0.16, 0.16), cf(0.35, 2.35, -0.83), DARK),
			-- Belly patch + the visible repair stitches across its head seam.
			part("Block", v3(0.8, 0.7, 0.1), cf(0.15, 0.95, -0.9, 0, 0, 12), rgb(120, 90, 60)),
			part("Block", v3(0.1, 0.45, 0.1), cf(-0.2, 2.9, -0.45, 0, 0, 30), DARK),
			part("Block", v3(0.1, 0.45, 0.1), cf(0.3, 2.85, -0.5, 0, 0, -25), DARK),
		}),
	}),
	table.freeze({
		id = "mopps",
		name = "Moppo Sloppo",
		rarity = "Uncommon",
		epithet = "Employee of the Month (Janitorial)",
		scale = 0.8,
		color = RARITY_COLORS.Uncommon,
		recipe = table.freeze({
			-- Shaggy sheepdog body: one fluff ball over a skirt of mop tendrils.
			part("Ball", v3(2, 2, 2), cf(0, 1.3, 0)),
			part("Cylinder", v3(1.4, 0.3, 0.3), cf(-0.7, 0.7, -0.45, 0, 0, 80)),
			part("Cylinder", v3(1.4, 0.3, 0.3), cf(0.7, 0.65, -0.4, 0, 0, 100)),
			part("Cylinder", v3(1.4, 0.3, 0.3), cf(-0.3, 0.6, 0.5, 0, 0, 95)),
			part("Cylinder", v3(1.4, 0.3, 0.3), cf(0.5, 0.7, 0.45, 0, 0, 85)),
			-- Bangs flopped over the face; exactly one googly eye peeks through.
			part("Block", v3(1.6, 0.5, 0.3), cf(0, 1.9, -0.85, 15, 0, 0)),
			part("Ball", v3(0.45, 0.45, 0.45), cf(0.35, 1.55, -0.95), WHITE),
			part("Ball", v3(0.22, 0.22, 0.22), cf(0.35, 1.5, -1.14), DARK),
			part("Ball", v3(0.35, 0.35, 0.35), cf(0, 1.2, -1), DARK),
			-- The gag: its tail is the mop handle, sticking straight up.
			part("Cylinder", v3(1.6, 0.2, 0.2), cf(0, 2.7, 0.6, 0, 0, 90), rgb(150, 110, 70)),
		}),
	}),
	table.freeze({
		id = "tapey",
		name = "Tape Tape Tapirino",
		rarity = "Uncommon",
		epithet = "Could Not Find the End",
		scale = 0.8,
		color = RARITY_COLORS.Uncommon,
		recipe = table.freeze({
			-- Packing-tape tapir: chunky body, round head, wiggly snoot.
			part("Block", v3(2.2, 1.3, 2), cf(0, 0.85, 0.2)),
			part("Ball", v3(1.3, 1.3, 1.3), cf(0, 1.55, -0.95)),
			part("Cylinder", v3(0.8, 0.35, 0.35), cf(0, 1.35, -1.75, 0, 90, 0)),
			-- Mismatched googly eyes.
			part("Ball", v3(0.44, 0.44, 0.44), cf(-0.34, 1.85, -1.45), WHITE),
			part("Ball", v3(0.34, 0.34, 0.34), cf(0.34, 1.8, -1.42), WHITE),
			part("Ball", v3(0.22, 0.22, 0.22), cf(-0.34, 1.85, -1.66), DARK),
			part("Ball", v3(0.16, 0.16, 0.16), cf(0.34, 1.8, -1.58), DARK),
			-- Stubby front legs.
			part("Block", v3(0.5, 0.7, 0.5), cf(-0.7, 0.35, -0.6)),
			part("Block", v3(0.5, 0.7, 0.5), cf(0.7, 0.35, -0.6)),
			-- The gag: a giant tape roll on its back, and the loose end of the
			-- strip stuck right across its own face. It cannot find it.
			part("Cylinder", v3(0.45, 1.2, 1.2), cf(0, 2, 0.55), rgb(205, 175, 95)),
			part("Block", v3(0.95, 0.26, 0.08), cf(0.05, 1.62, -1.58, 0, 0, 18), rgb(228, 212, 165)),
		}),
	}),
	table.freeze({
		id = "honku",
		name = "Honk Honk Squeakini",
		rarity = "Uncommon",
		epithet = "Failed Squeak Inspection",
		scale = 0.8,
		color = RARITY_COLORS.Uncommon,
		recipe = table.freeze({
			-- Rubber-duck goose: bath-toy body with a periscope neck.
			part("Ball", v3(2, 2, 2), cf(0, 1, 0.1)),
			part("Cylinder", v3(1, 0.45, 0.45), cf(0, 1.9, -0.6, 0, 0, 90)),
			part("Ball", v3(1.1, 1.1, 1.1), cf(0, 2.55, -0.65)),
			part("Wedge", v3(0.4, 0.3, 0.55), cf(0, 2.45, -1.35, 0, 180, 0), rgb(240, 170, 60)),
			-- Mismatched googly eyes.
			part("Ball", v3(0.4, 0.4, 0.4), cf(-0.28, 2.75, -1.05), WHITE),
			part("Ball", v3(0.32, 0.32, 0.32), cf(0.3, 2.7, -1), WHITE),
			part("Ball", v3(0.2, 0.2, 0.2), cf(-0.28, 2.75, -1.23), DARK),
			part("Ball", v3(0.16, 0.16, 0.16), cf(0.3, 2.7, -1.14), DARK),
			-- Stubby bath-toy wings + tail flip.
			part("Wedge", v3(0.25, 0.9, 0.7), cf(-1.05, 1.1, 0.1, 0, 0, 30)),
			part("Wedge", v3(0.25, 0.9, 0.7), cf(1.05, 1.1, 0.1, 0, 0, -30)),
			part("Wedge", v3(0.6, 0.6, 0.7), cf(0, 1.5, 1.05, -20, 0, 0)),
			-- The gag: the belly squeaker shipped on the OUTSIDE. It honks.
			part("Cylinder", v3(0.3, 0.75, 0.75), cf(0, 0.95, -0.95, 0, 90, 0), rgb(220, 55, 55)),
		}),
	}),
	-- RARES --------------------------------------------------------------
	table.freeze({
		id = "sploot",
		name = "Splootus Maximus",
		rarity = "Rare",
		epithet = "Structural Integrity: No",
		scale = 1,
		color = RARITY_COLORS.Rare,
		recipe = table.freeze({
			-- Corgi front half: proud chest, big round head, tall ears.
			part("Ball", v3(1.5, 1.5, 1.5), cf(0, 0.8, -0.8)),
			part("Ball", v3(1.3, 1.3, 1.3), cf(0, 1.6, -1.1)),
			part("Wedge", v3(0.45, 0.6, 0.35), cf(-0.45, 2.4, -1)),
			part("Wedge", v3(0.45, 0.6, 0.35), cf(0.45, 2.4, -1)),
			-- Huge happy mismatched googly eyes + tongue out.
			part("Ball", v3(0.42, 0.42, 0.42), cf(-0.3, 1.75, -1.62), WHITE),
			part("Ball", v3(0.34, 0.34, 0.34), cf(0.32, 1.7, -1.6), WHITE),
			part("Ball", v3(0.2, 0.2, 0.2), cf(-0.3, 1.75, -1.8), DARK),
			part("Ball", v3(0.16, 0.16, 0.16), cf(0.32, 1.7, -1.76), DARK),
			part("Block", v3(0.3, 0.4, 0.1), cf(0, 1.15, -1.7, 20, 0, 0), rgb(235, 120, 150)),
			-- The gag: the entire back half is splooted pancake-flat,
			-- stubby legs splayed straight back.
			part("Block", v3(1.8, 0.35, 2.2), cf(0, 0.18, 1)),
			part("Block", v3(0.45, 0.25, 1), cf(-0.75, 0.13, 1.9, 0, 15, 0)),
			part("Block", v3(0.45, 0.25, 1), cf(0.75, 0.13, 1.9, 0, -15, 0)),
		}),
	}),
	table.freeze({
		id = "glitch",
		name = "Glitcherino",
		rarity = "Rare",
		epithet = "Render Error",
		scale = 1,
		color = RARITY_COLORS.Rare,
		recipe = table.freeze({
			-- Front half renders fine: cat chest, round head, pointy ears.
			part("Block", v3(1.4, 1.5, 1.2), cf(0, 0.75, -0.5)),
			part("Ball", v3(1.4, 1.4, 1.4), cf(0, 1.9, -0.8)),
			part("Wedge", v3(0.45, 0.55, 0.35), cf(-0.5, 2.7, -0.8)),
			part("Wedge", v3(0.45, 0.55, 0.35), cf(0.5, 2.7, -0.8)),
			-- One googly eye where it belongs...
			part("Ball", v3(0.4, 0.4, 0.4), cf(-0.3, 2, -1.35), WHITE),
			part("Ball", v3(0.2, 0.2, 0.2), cf(-0.3, 2, -1.53), DARK),
			-- ...the other displaced clean off the head (render error).
			part("Ball", v3(0.34, 0.34, 0.34), cf(0.95, 2.45, -1), WHITE),
			part("Ball", v3(0.18, 0.18, 0.18), cf(0.95, 2.45, -1.15), DARK),
			-- The back half failed to composite: cyan/magenta ghost duplicates
			-- plus a glitched tail fragment.
			part("Block", v3(1.4, 1.3, 1.3), cf(0.35, 0.95, 0.7), GHOST_CYAN),
			part("Block", v3(1.4, 1.3, 1.3), cf(-0.3, 0.7, 0.85), GHOST_MAGENTA),
			part("Block", v3(0.25, 0.9, 0.25), cf(0.5, 1.75, 1.3, 0, 0, -20), GHOST_CYAN),
		}),
	}),
	table.freeze({
		id = "furnace",
		name = "Furnacino Inferno",
		rarity = "Rare",
		epithet = "OSHA Violation",
		scale = 1,
		color = RARITY_COLORS.Rare,
		recipe = table.freeze({
			-- Boxy toaster-dragon: appliance body, blocky head, ember belly.
			part("Block", v3(2, 2, 1.5), cf(0, 1, 0)),
			part("Block", v3(1.3, 1, 1.1), cf(0, 2.5, -0.3)),
			part("Block", v3(1.2, 1, 0.12), cf(0, 0.95, -0.78), rgb(255, 120, 40)),
			-- Mouth is a toast slot, and mismatched googly eyes above it.
			part("Block", v3(0.9, 0.3, 0.1), cf(0, 2.25, -0.88), DARK),
			part("Ball", v3(0.4, 0.4, 0.4), cf(-0.32, 2.7, -0.82), WHITE),
			part("Ball", v3(0.32, 0.32, 0.32), cf(0.32, 2.68, -0.8), WHITE),
			part("Ball", v3(0.2, 0.2, 0.2), cf(-0.32, 2.7, -1), DARK),
			part("Ball", v3(0.16, 0.16, 0.16), cf(0.32, 2.68, -0.95), DARK),
			-- Tiny useless dragon wings.
			part("Wedge", v3(0.2, 0.8, 0.7), cf(-1.1, 1.8, 0.3, 0, 0, 40)),
			part("Wedge", v3(0.2, 0.8, 0.7), cf(1.1, 1.8, 0.3, 0, 0, -40)),
			-- The gag: a slice of toast mid-pop out of the top of its head.
			part("Wedge", v3(0.7, 0.7, 0.25), cf(0.15, 3.3, -0.3, 0, 0, -15), rgb(225, 185, 120)),
		}),
	}),
	table.freeze({
		id = "boxo",
		name = "Cartoni Tortelloni",
		rarity = "Rare",
		epithet = "This Side Up (It Was Not)",
		scale = 1,
		color = RARITY_COLORS.Rare,
		recipe = table.freeze({
			-- Box turtle, literally: squat body with a head poking out front.
			part("Block", v3(2, 0.8, 2.4), cf(0, 0.6, 0.1)),
			part("Ball", v3(0.95, 0.95, 0.95), cf(0, 1.05, -1.5)),
			-- Mismatched googly eyes.
			part("Ball", v3(0.4, 0.4, 0.4), cf(-0.26, 1.25, -1.85), WHITE),
			part("Ball", v3(0.3, 0.3, 0.3), cf(0.26, 1.2, -1.8), WHITE),
			part("Ball", v3(0.2, 0.2, 0.2), cf(-0.26, 1.25, -2.03), DARK),
			part("Ball", v3(0.14, 0.14, 0.14), cf(0.26, 1.2, -1.93), DARK),
			-- Stubby leg stumps.
			part("Block", v3(0.5, 0.5, 0.5), cf(-0.85, 0.25, -0.7)),
			part("Block", v3(0.5, 0.5, 0.5), cf(0.85, 0.25, -0.7)),
			-- The gag: its shell is a shipping carton, flaps still open, with
			-- the THIS SIDE UP arrow stamped on the front pointing straight down.
			part("Block", v3(1.8, 1.2, 1.9), cf(0, 1.6, 0.4), rgb(190, 150, 100)),
			part("Block", v3(0.85, 0.12, 0.9), cf(-0.55, 2.3, 0.4, 0, 0, 25), rgb(175, 135, 90)),
			part("Block", v3(0.85, 0.12, 0.9), cf(0.55, 2.35, 0.4, 0, 0, -35), rgb(175, 135, 90)),
			part("Wedge", v3(0.5, 0.5, 0.14), cf(0, 1.45, -0.59, 180, 0, 0), WHITE),
		}),
	}),
	table.freeze({
		id = "sproing",
		name = "Boing Boing Sproingetti",
		rarity = "Rare",
		epithet = "Recoil Hazard",
		scale = 1,
		color = RARITY_COLORS.Rare,
		recipe = table.freeze({
			-- Slinky dachshund: a proud front half, ears up, ready to go.
			part("Ball", v3(1.4, 1.4, 1.4), cf(0, 0.7, -1.3)),
			part("Ball", v3(1.2, 1.2, 1.2), cf(0, 1.6, -1.5)),
			part("Wedge", v3(0.4, 0.55, 0.35), cf(-0.45, 2.35, -1.45)),
			part("Wedge", v3(0.4, 0.55, 0.35), cf(0.45, 2.35, -1.45)),
			-- Mismatched googly eyes.
			part("Ball", v3(0.4, 0.4, 0.4), cf(-0.28, 1.75, -2), WHITE),
			part("Ball", v3(0.32, 0.32, 0.32), cf(0.3, 1.7, -1.97), WHITE),
			part("Ball", v3(0.2, 0.2, 0.2), cf(-0.28, 1.75, -2.18), DARK),
			part("Ball", v3(0.16, 0.16, 0.16), cf(0.3, 1.7, -2.11), DARK),
			-- The gag: the middle of the dog is a factory spring. Boing.
			part("Cylinder", v3(0.3, 1.1, 1.1), cf(0, 0.85, -0.45, 0, 90, 0), rgb(150, 150, 160)),
			part("Cylinder", v3(0.3, 1.1, 1.1), cf(0, 0.9, 0.1, 0, 90, 0), rgb(150, 150, 160)),
			part("Cylinder", v3(0.3, 1.1, 1.1), cf(0, 0.85, 0.65, 0, 90, 0), rgb(150, 150, 160)),
			-- The back half, still catching up from yesterday.
			part("Ball", v3(1.1, 1.1, 1.1), cf(0, 0.55, 1.55)),
		}),
	}),
	-- EPICS --------------------------------------------------------------
	table.freeze({
		id = "inkblot",
		name = "Blotto",
		rarity = "Epic",
		epithet = "The Stain Spreads",
		scale = 1.3,
		color = RARITY_COLORS.Epic,
		recipe = table.freeze({
			-- Ink octopus: dome head over a skirt of drooping tentacles.
			part("Ball", v3(2, 2, 2), cf(0, 1.8, 0), INK),
			part("Cylinder", v3(1.3, 0.35, 0.35), cf(-0.9, 0.6, -0.4, 0, 0, 70), INK),
			part("Cylinder", v3(1.3, 0.35, 0.35), cf(0.9, 0.6, -0.4, 0, 0, 110), INK),
			part("Cylinder", v3(1.3, 0.35, 0.35), cf(-0.6, 0.55, 0.6, 0, 0, 75), INK),
			part("Cylinder", v3(1.3, 0.35, 0.35), cf(0.7, 0.6, 0.55, 0, 0, 105), INK),
			-- Huge mismatched googly eyes glowing out of the ink.
			part("Ball", v3(0.7, 0.7, 0.7), cf(-0.4, 2, -0.85), WHITE),
			part("Ball", v3(0.55, 0.55, 0.55), cf(0.45, 1.9, -0.85), WHITE),
			part("Ball", v3(0.32, 0.32, 0.32), cf(-0.4, 2, -1.14), DARK),
			part("Ball", v3(0.26, 0.26, 0.26), cf(0.45, 1.9, -1.1), DARK),
			-- The gag: a fifth tentacle curls out front clutching a tiny pen
			-- (the ink has to come from somewhere).
			part("Cylinder", v3(1.2, 0.3, 0.3), cf(1.3, 1, -0.6, 0, 0, 140), INK),
			part("Cylinder", v3(0.9, 0.12, 0.12), cf(1.7, 0.7, -0.8, 0, 0, 45), WHITE),
		}),
	}),
	table.freeze({
		id = "vacuumo",
		name = "Vacuumini Elefantini",
		rarity = "Epic",
		epithet = "It Ate the Small Parts Bin",
		scale = 1.3,
		color = RARITY_COLORS.Epic,
		recipe = table.freeze({
			-- Shop-vac elephant: canister-drum body with a round head on top.
			part("Cylinder", v3(2, 1.9, 1.9), cf(0, 1, 0.2, 0, 0, 90)),
			part("Ball", v3(1.5, 1.5, 1.5), cf(0, 2.5, -0.3)),
			-- Big flat ears, one mounted noticeably higher (QC missed it).
			part("Block", v3(0.18, 1.1, 0.9), cf(-0.85, 2.6, 0), DARK),
			part("Block", v3(0.18, 1.1, 0.9), cf(0.85, 2.85, 0), DARK),
			-- Mismatched googly eyes.
			part("Ball", v3(0.5, 0.5, 0.5), cf(-0.34, 2.75, -0.95), WHITE),
			part("Ball", v3(0.4, 0.4, 0.4), cf(0.36, 2.7, -0.9), WHITE),
			part("Ball", v3(0.24, 0.24, 0.24), cf(-0.34, 2.75, -1.17), DARK),
			part("Ball", v3(0.18, 0.18, 0.18), cf(0.36, 2.7, -1.08), DARK),
			-- The gag: the trunk is a vacuum hose, frozen mid-slurp on a part
			-- it absolutely was not supposed to inhale.
			part("Cylinder", v3(1.1, 0.34, 0.34), cf(0, 2.1, -1.45, 0, 90, 0), DARK),
			part("Cylinder", v3(1.5, 0.34, 0.34), cf(0, 1.05, -1.9, 0, 0, 90), DARK),
			part("Block", v3(0.32, 0.32, 0.32), cf(0, 0.16, -1.9, 0, 25, 0), rgb(230, 200, 60)),
		}),
	}),
	table.freeze({
		id = "conveyo",
		name = "Conveyo Slothino",
		rarity = "Epic",
		epithet = "Line Speed: Way Too Fast",
		scale = 1.3,
		color = RARITY_COLORS.Epic,
		recipe = table.freeze({
			-- The gag: it shipped still bolted to its own piece of conveyor
			-- belt, rollers and all, forever riding the line.
			part("Block", v3(2.6, 0.3, 1.7), cf(0, 0.65, 0), DARK),
			part("Cylinder", v3(1.8, 0.5, 0.5), cf(0, 0.25, -0.55), rgb(150, 150, 160)),
			part("Cylinder", v3(1.8, 0.5, 0.5), cf(0, 0.25, 0.55), rgb(150, 150, 160)),
			-- Sloth on top: fuzzy lump body, round head, droopy hook arms.
			part("Ball", v3(1.5, 1.5, 1.5), cf(0, 1.5, 0.15)),
			part("Ball", v3(1.1, 1.1, 1.1), cf(0, 2.45, -0.25)),
			part("Cylinder", v3(1.1, 0.3, 0.3), cf(-0.75, 1.25, -0.35, 0, 0, 65)),
			part("Cylinder", v3(1.1, 0.3, 0.3), cf(0.75, 1.2, -0.35, 0, 0, 115)),
			-- Sleepy mismatched googly eyes (it has been on shift forever).
			part("Ball", v3(0.4, 0.4, 0.4), cf(-0.26, 2.6, -0.7), WHITE),
			part("Ball", v3(0.32, 0.32, 0.32), cf(0.28, 2.55, -0.66), WHITE),
			part("Ball", v3(0.2, 0.2, 0.2), cf(-0.26, 2.6, -0.88), DARK),
			part("Ball", v3(0.16, 0.16, 0.16), cf(0.28, 2.55, -0.8), DARK),
		}),
	}),
	-- LEGENDARY (the old Godly slot: same item, same pull rates, now red) --
	table.freeze({
		id = "prototype_zero",
		name = "Robo Houndini",
		rarity = "Legendary",
		-- (scale ladder, widened: C 0.6 / U 0.8 / R 1 / E 1.3 / L 1.6 / G 2 / M 2.5)
		scale = 1.6,
		epithet = "Unit 000 — Do Not Reactivate",
		color = RARITY_COLORS.Legendary,
		recipe = table.freeze({
			-- Robot guard dog: angular torso slung low, blocky head out front.
			part("Block", v3(2.2, 1.3, 2.6), cf(0, 1.5, 0.1)),
			part("Block", v3(1.2, 1, 1.2), cf(0, 2.6, -1.3)),
			-- Optic sensors: mismatched googly camera eyes.
			part("Ball", v3(0.42, 0.42, 0.42), cf(-0.3, 2.8, -1.85), WHITE),
			part("Ball", v3(0.34, 0.34, 0.34), cf(0.32, 2.75, -1.83), WHITE),
			part("Ball", v3(0.2, 0.2, 0.2), cf(-0.3, 2.8, -2.04), DARK),
			part("Ball", v3(0.16, 0.16, 0.16), cf(0.32, 2.75, -1.98), DARK),
			-- Three rigid strut legs...
			part("Block", v3(0.5, 0.9, 0.5), cf(-0.7, 0.45, -0.9)),
			part("Block", v3(0.5, 0.9, 0.5), cf(0.7, 0.45, -0.9)),
			part("Block", v3(0.5, 0.9, 0.5), cf(-0.7, 0.45, 1.1)),
			-- ...and the gag: leg four shipped as a wheel. Do not reactivate.
			part("Cylinder", v3(0.3, 0.9, 0.9), cf(0.7, 0.45, 1.1), DARK),
			-- Antenna tail + the glowing core seam along its spine.
			part("Cylinder", v3(1.5, 0.15, 0.15), cf(0, 2.6, 1.4, 0, 0, 70), DARK),
			part("Block", v3(0.14, 0.7, 2.2), cf(0, 2.1, 0.1), rgb(255, 70, 50)),
		}),
	}),
	table.freeze({
		id = "forklift",
		name = "Forklifto Giraffeloni",
		rarity = "Legendary",
		scale = 1.6,
		epithet = "Certified Operator (License Revoked)",
		color = RARITY_COLORS.Legendary,
		recipe = table.freeze({
			-- Giraffe forklift: chassis body on axle wheels, mast neck, tiny
			-- head way up top surveying the warehouse.
			part("Block", v3(2, 1.2, 2.4), cf(0, 1.1, 0.3)),
			part("Cylinder", v3(2.3, 0.9, 0.9), cf(0, 0.45, -0.6), DARK),
			part("Cylinder", v3(2.3, 0.9, 0.9), cf(0, 0.45, 1.1), DARK),
			part("Block", v3(0.55, 2.4, 0.55), cf(0, 2.85, -0.8)),
			part("Block", v3(0.9, 0.7, 1.2), cf(0, 4.25, -1.15)),
			-- Mismatched googly eyes, four studs off the ground.
			part("Ball", v3(0.38, 0.38, 0.38), cf(-0.24, 4.4, -1.78), WHITE),
			part("Ball", v3(0.3, 0.3, 0.3), cf(0.26, 4.35, -1.73), WHITE),
			part("Ball", v3(0.18, 0.18, 0.18), cf(-0.24, 4.4, -1.95), DARK),
			part("Ball", v3(0.14, 0.14, 0.14), cf(0.26, 4.35, -1.86), DARK),
			-- The gag: real fork prongs out front, proudly carrying one (1)
			-- very small box. Heavy machinery. Zero training.
			part("Block", v3(0.28, 0.16, 1.3), cf(-0.4, 0.14, -1.95), DARK),
			part("Block", v3(0.28, 0.16, 1.3), cf(0.4, 0.14, -1.95), DARK),
			part("Block", v3(0.75, 0.75, 0.75), cf(0, 0.6, -2, 0, 12, 0), rgb(190, 150, 100)),
		}),
	}),
	-- GODLY (10x rarer than Legendary — the chase tier) --------------------
	table.freeze({
		id = "foreman_prime",
		name = "Gorillionaire",
		rarity = "Godly",
		epithet = "The Night Shift Answers to Him",
		scale = 2,
		color = RARITY_COLORS.Godly,
		recipe = table.freeze({
			-- Gold gorilla overseer: squat haunches, massive chest, round head.
			part("Block", v3(1.8, 0.9, 1.3), cf(0, 0.45, 0.2)),
			part("Block", v3(2.8, 2, 1.6), cf(0, 1.9, 0)),
			part("Ball", v3(1.3, 1.3, 1.3), cf(0, 3.3, -0.2)),
			-- The gag: a hardhat three sizes too small, brim and all.
			part("Block", v3(1, 0.4, 0.9), cf(0, 4, -0.2), rgb(255, 210, 80)),
			part("Wedge", v3(0.9, 0.25, 0.5), cf(0, 3.9, -0.85, 0, 180, 0), rgb(255, 210, 80)),
			-- One burning white eye, one dead dark squint.
			part("Ball", v3(0.55, 0.55, 0.55), cf(-0.28, 3.4, -0.7), WHITE),
			part("Ball", v3(0.22, 0.22, 0.22), cf(0.32, 3.35, -0.74), DARK),
			-- Knuckle-down arms ending in boulder fists.
			part("Block", v3(0.7, 2.2, 0.7), cf(-1.75, 1.3, -0.3, 0, 0, 12)),
			part("Block", v3(0.7, 2.2, 0.7), cf(1.75, 1.3, -0.3, 0, 0, -12)),
			part("Ball", v3(0.85, 0.85, 0.85), cf(-2, 0.42, -0.3), DARK),
			part("Ball", v3(0.85, 0.85, 0.85), cf(2, 0.42, -0.3), DARK),
			-- Management's chain of office, slung across the chest.
			part("Cylinder", v3(2.6, 0.3, 0.3), cf(0, 2.5, -0.85, 0, 0, -20), DARK),
		}),
	}),
	table.freeze({
		id = "static_king",
		name = "Staticelli Parrotelli",
		rarity = "Godly",
		epithet = "All Channels. All Hail.",
		scale = 2,
		color = RARITY_COLORS.Godly,
		recipe = table.freeze({
			-- Round parrot body wearing a TV for a head.
			part("Ball", v3(1.8, 1.8, 1.8), cf(0, 1, 0)),
			part("Block", v3(1.9, 1.5, 1.2), cf(0, 2.6, 0), DARK),
			part("Block", v3(1.5, 1.1, 0.12), cf(0, 2.6, -0.62), rgb(220, 230, 240)),
			-- The static face: mismatched googly eyes drifting mid-broadcast.
			part("Ball", v3(0.45, 0.45, 0.45), cf(-0.35, 2.75, -0.72), WHITE),
			part("Ball", v3(0.34, 0.34, 0.34), cf(0.38, 2.5, -0.7), WHITE),
			part("Ball", v3(0.22, 0.22, 0.22), cf(-0.35, 2.75, -0.92), DARK),
			part("Ball", v3(0.18, 0.18, 0.18), cf(0.38, 2.5, -0.86), DARK),
			-- Beak poking out from under the set, wing wedges, antenna crown.
			part("Wedge", v3(0.4, 0.35, 0.5), cf(0, 1.7, -0.95, 0, 180, 0), rgb(255, 160, 60)),
			part("Wedge", v3(0.25, 1, 0.8), cf(-1.05, 1.1, 0, 0, 0, 30)),
			part("Wedge", v3(0.25, 1, 0.8), cf(1.05, 1.1, 0, 0, 0, -30)),
			part("Cylinder", v3(1.2, 0.15, 0.15), cf(-0.4, 3.7, 0, 0, 0, 60)),
			part("Cylinder", v3(1.2, 0.15, 0.15), cf(0.4, 3.7, 0, 0, 0, -60)),
		}),
	}),
	-- MYTHICAL (rainbow, 1-in-100,000) --------------------------------------
	table.freeze({
		id = "polychrome",
		name = "Axolotto Polychromo",
		rarity = "Mythical",
		epithet = "The Misprint That Came Out Perfect",
		scale = 2.5,
		color = RARITY_COLORS.Mythical,
		recipe = table.freeze({
			-- Rainbow axolotl, the misprint that came out PERFECT: every major
			-- part a different band of the rainbow (the tier's in-world rainbow).
			part("Ball", v3(2.2, 2.2, 2.2), cf(0, 1.7, -0.7), rgb(235, 70, 60)),
			part("Block", v3(1.5, 1.4, 2), cf(0, 0.7, 0.5), rgb(245, 150, 50)),
			-- Frill spikes fanning off the head, one band per side.
			part("Wedge", v3(0.3, 0.7, 0.9), cf(-1.2, 2.1, -0.7, 0, 0, 55), rgb(240, 210, 60)),
			part("Wedge", v3(0.3, 0.7, 0.9), cf(1.2, 2.1, -0.7, 0, 0, -55), rgb(90, 200, 90)),
			-- Tiny dangling arms + curled-up tail finish the seven bands.
			part("Block", v3(0.3, 0.7, 0.3), cf(-0.8, 0.5, -1, 0, 0, 15), rgb(70, 150, 230)),
			part("Block", v3(0.3, 0.7, 0.3), cf(0.8, 0.5, -1, 0, 0, -15), rgb(120, 80, 210)),
			part("Wedge", v3(0.5, 1, 1.4), cf(0, 1.1, 2, -35, 0, 0), rgb(220, 90, 200)),
			-- Big sweet mismatched googly eyes and a stamped-on smile.
			part("Ball", v3(0.55, 0.55, 0.55), cf(-0.45, 1.95, -1.6), WHITE),
			part("Ball", v3(0.45, 0.45, 0.45), cf(0.45, 1.9, -1.58), WHITE),
			part("Ball", v3(0.26, 0.26, 0.26), cf(-0.45, 1.95, -1.83), DARK),
			part("Ball", v3(0.22, 0.22, 0.22), cf(0.45, 1.9, -1.78), DARK),
			part("Block", v3(0.8, 0.12, 0.15), cf(0, 1.3, -1.72), DARK),
		}),
	}),
	-- SPECIAL: not in any roll pool, not tradeable ------------------------
	table.freeze({
		id = "misprint_trophy",
		name = "Misprint Trophy",
		rarity = "Epic",
		color = RARITY_COLORS.Epic,
		notInPool = true,
		tradeable = false, -- Starter Pack exclusive shelf item (§4.2)
		recipe = table.freeze({
			part("Cylinder", v3(0.4, 1.8, 1.8), cf(0, 0.2, 0, 0, 0, 90), rgb(90, 70, 40)),
			part("Block", v3(1.2, 0.5, 0.15), cf(0, 0.55, -0.85), rgb(220, 200, 120)),
			part("Ball", v3(1.1, 1.1, 1.1), cf(0, 1.3, 0), rgb(235, 190, 52)),
			part("Block", v3(0.7, 0.7, 0.7), cf(0.3, 2, 0.1, 0, 15, 25), rgb(235, 190, 52)),
			part("Ball", v3(0.25, 0.25, 0.25), cf(0.35, 2.05, -0.35), WHITE),
			part("Wedge", v3(0.4, 0.6, 0.5), cf(-0.4, 0.9, 0.4), rgb(200, 160, 40)),
		}),
	}),
})

--------------------------------------------------------------------------------
-- Indexes
--------------------------------------------------------------------------------

local byId: { [string]: any } = {}
local poolByRarity: { [string]: { any } } = {}
for _, rarity in RARITY_ORDER do
	poolByRarity[rarity] = {}
end
for _, def in CRYPTLINGS do
	byId[def.id] = def
	if not def.notInPool then
		table.insert(poolByRarity[def.rarity], def)
	end
end
table.freeze(byId)
for _, pool in poolByRarity do
	table.freeze(pool)
end
table.freeze(poolByRarity)

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

local RarityTable = {}

RarityTable.RARITY_ORDER = RARITY_ORDER
RarityTable.RARITY_COLORS = RARITY_COLORS
RarityTable.RARITY_DISPLAY = RARITY_DISPLAY
RarityTable.RARITY_EPITHETS = RARITY_EPITHETS
RarityTable.WEIGHT_TOTAL = WEIGHT_TOTAL
RarityTable.BASELINE_TIER = BASELINE_TIER
RarityTable.TIER_WEIGHTS = TIER_WEIGHTS
RarityTable.CRYPTLINGS = CRYPTLINGS
RarityTable.LINE_ID = "line1"
RarityTable.LINE_NAME = "Factory Floor Misfits"

function RarityTable.GetCryptling(id: string): any
	return byId[id]
end

-- Spec-name alias for GetCryptling (Stage 0 contract: GetEntry(id)).
RarityTable.GetEntry = RarityTable.GetCryptling

-- In-pool members of a rarity (excludes notInPool entries like misprint_trophy).
function RarityTable.GetPoolByRarity(rarity: string): { any }
	return poolByRarity[rarity] or table.freeze({})
end

function RarityTable.GetWeights(tier: number): { [string]: number }
	local weights = TIER_WEIGHTS[tier]
	assert(weights ~= nil, `RarityTable.GetWeights: invalid case tier {tier}`)
	return weights
end

-- EXACT disclosed odds, ordered Common -> Godly. This single table feeds the hub
-- odds board AND every pre-purchase disclosure via the GetOddsTable remote (§8.1).
function RarityTable.GetOdds(tier: number): { { rarity: string, pct: number } }
	local weights = RarityTable.GetWeights(tier)
	local odds = {}
	for _, rarity in RARITY_ORDER do
		-- weight/10000 with WEIGHT_TOTAL = 1,000,000 — kept generic so the
		-- disclosed numbers stay exact if the resolution ever changes again.
		table.insert(odds, { rarity = rarity, pct = weights[rarity] * 100 / WEIGHT_TOTAL })
	end
	return odds
end

-- Weighted rarity pick from a roll in [0, 1). Pure and deterministic.
function RarityTable.RollRarity(tier: number, roll01: number): string
	local weights = RarityTable.GetWeights(tier)
	local threshold = roll01 * WEIGHT_TOTAL
	local cumulative = 0
	for _, rarity in RARITY_ORDER do
		cumulative += weights[rarity]
		if threshold < cumulative then
			return rarity
		end
	end
	return RARITY_ORDER[#RARITY_ORDER]
end

-- Full roll: weighted rarity pick, then uniform among that rarity's in-pool
-- members. `rng` must return a number in [0, 1) (e.g. wrap Random.NextNumber).
-- Server-side use only (UnboxService).
function RarityTable.Roll(tier: number, rng: () -> number): string
	local rarity = RarityTable.RollRarity(tier, rng())
	local pool = poolByRarity[rarity]
	assert(#pool > 0, `RarityTable.Roll: empty pool for rarity {rarity}`)
	local index = math.min(#pool, math.floor(rng() * #pool) + 1)
	return pool[index].id
end

-- Spec-name alias for Roll (Stage 0 contract: RollCryptling(tier, rng)).
RarityTable.RollCryptling = RarityTable.Roll

return table.freeze(RarityTable)
