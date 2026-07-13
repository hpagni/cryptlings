--!strict
-- CRYPTLINGS: NIGHT SHIFT — WallBuilder: the Current Factory Brainrots wall
-- (LOBBY_SOP §7 as amended by Addendum 1 Changes 7 & 3; R2 WP2.2).
--
-- Pure construction, invoked only by the HubService orchestrator: no signals,
-- no connections, no player logic, no Init/Start. The wall's card grid is a
-- CLIENT SurfaceGui (BrainrotWallUI, WP3.6, finds the slab via the
-- "BrainrotWall" tag and sets Adornee in code); the server only ships the
-- slab, header, wash light, and 1-3 oversized hero podium figures of the
-- rarest rotation Cryptlings. Heroes are server-built STATIC — the client
-- HeroFXController (Addendum 1 Change 3) binds the "HeroFigure" tag to spin
-- them, add Highlight/sparkles, and run RarityFX.Apply with noLights/
-- noMotion. The figures are fully text-free (Addendum 2 R3-2) — name duty
-- lives on this wall's card grid, never on a floating label. This file adds
-- zero Lights and zero emitters for heroes.
--
-- Layout convention (shared by every LobbyBuild builder): street axis = X
-- with the Factory at the EAST end; the 10-lot strip
-- (LOTS_PER_SIDE * LOT_FRONTAGE + 9 * LOT_GAP = 522 studs) is centered on
-- `origin`, so the Factory facade plane sits at +261 + FACTORY_PLAZA_DEPTH
-- = +361. The slab hangs on that facade facing the queue pad (front face
-- west, 0.05 studs proud of the plane so FactoryBuilder's wall never
-- z-fights it).
--
-- Facade fixture footprint (so FactoryBuilder/QueuePadBuilder stay clear):
-- slab z in [-24, 24] at y in [7.5, 21.5]; header board above it up to
-- y 24.5; QueuePadBuilder's Best Employees board sits below at z in [10, 26],
-- y in [1.5, 7]. Hero podiums stand on the plaza floor SOUTH of the pad
-- approach (Best-Employees side, nearest plinth edge at z ~= 14; Addendum 2
-- R3-1), clear of the z in [-7, 7] walk line and the street->pad corridor.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local LobbyConfig = require(Shared:WaitForChild("Config"):WaitForChild("LobbyConfig"))
local RarityTable = require(Shared:WaitForChild("Config"):WaitForChild("RarityTable"))

local PartKit = require(script.Parent:WaitForChild("PartKit"))

--------------------------------------------------------------------------------
-- Layout constants (derived from LobbyConfig — shared builder convention)
--------------------------------------------------------------------------------

local LOT_STRIP_LENGTH = LobbyConfig.LOTS_PER_SIDE * LobbyConfig.LOT_FRONTAGE_STUDS
	+ (LobbyConfig.LOTS_PER_SIDE - 1) * LobbyConfig.LOT_GAP_STUDS
local FACADE_X = LOT_STRIP_LENGTH / 2 + LobbyConfig.FACTORY_PLAZA_DEPTH_STUDS

local WALL_BOTTOM_Y = 7.5 -- keeps the roster board strip (y <= 7) clear below
local WALL_THICKNESS = 1
local HEADER_HEIGHT = 3

local TAG_WALL = "BrainrotWall" -- BrainrotWallUI adorns its SurfaceGui via this tag
local HEADER_TEXT = "Current Factory Brainrots" -- Addendum 1 Change 7 verbatim
local TAG_HERO = "HeroFigure" -- HeroFXController binds this (Addendum 1 Change 3)

-- Hero podium figures: oversized showcases of the rarest rotation Cryptlings.
-- Server-side they are static greybox (no spin/bob, no Lights, no emitters);
-- HeroFXController owns all motion/FX client-side off the HeroIndex attr.
-- Ring numbers (footprint factor / height / transparency) come from
-- LobbyConfig.HERO — the guaranteed rarity read at all quality levels.
local HERO_COUNT = 3
local HERO_SCALE = 1.15 -- on top of each def's own scale ladder (~2x shelf size)
local HERO_MAX_HEIGHT = 9
local HERO_PLINTH_DIAMETER = 4
local HERO_PLINTH_HEIGHT = 1
-- Plaza-floor offsets from the facade plane, SOUTH of the pad approach
-- (Addendum 2 R3-1: the Best-Employees side, +Z = south — the RIGHT of the
-- clock-in station for a player facing the Factory; the Brainrot wall mount
-- owns the north). Shallow arc at a 12-stud X pitch; the middle figure sits
-- 3 studs deeper at the arc apex, x-aligned with the pad center
-- (FACADE_X - 26), so `CFrame.lookAt(basePosition, padCenter)` below yaws
-- every figure toward the pad for free. Constraints these numbers honor:
--   * nearest collidable plinth edge >= 7 studs from the pad's south edge
--     (pad spans z -7..+7; nearest plinth edge at z ~= 14);
--   * nothing in the pad->door dispatch lane (|z| <= 7) or the street->pad
--     approach corridor;
--   * >= 8 studs facade clearance (C at x = -14 clears the Best Employees
--     board strip).
-- Selection is rarest-first (selectHeroDefs), so index 2 should carry the
-- rarest def: selectHeroDefs reorders the picks so the RAREST lands at
-- HeroIndex 2 (the apex slot) while HeroIndex attrs stay positional 1..3
-- for the client phase offsets.
local HERO_OFFSETS: { Vector3 } = {
	Vector3.new(-38, 0, 16), -- A (west, farthest from the facade)
	Vector3.new(-26, 0, 19), -- B (middle: arc apex, pad-center X, rarest)
	Vector3.new(-14, 0, 16), -- C (east, nearest the facade)
}

--------------------------------------------------------------------------------
-- Night greybox palette (thematic, build-local; SOP numbers stay in LobbyConfig)
--------------------------------------------------------------------------------

local COLOR_SLAB = Color3.fromRGB(26, 25, 32)
local COLOR_HEADER_BOARD = Color3.fromRGB(20, 19, 25)
local COLOR_PLINTH = Color3.fromRGB(52, 52, 58) -- SmoothPlastic dark gray (SOP §4.2)
local COLOR_LIGHT_COOL = Color3.fromRGB(200, 215, 255)

local function toColor3(c: { R: number, G: number, B: number }): Color3
	return Color3.fromRGB(c.R, c.G, c.B)
end

--------------------------------------------------------------------------------
-- Types
--------------------------------------------------------------------------------

export type WallBuild = {
	model: Model,
	wallPart: BasePart,
	headerLabel: TextLabel,
	surfaceLight: SurfaceLight,
	heroFigures: { Model },
}

local WallBuilder = {}

--------------------------------------------------------------------------------
-- Hero figure rendering (recipe = THE render spec; static greybox port of the
-- shelf display renderer, decor-flagged per SOP §4.5)
--------------------------------------------------------------------------------

-- Rarest-first selection straight from the rotation pools: walk RARITY_ORDER
-- from the top tier down until HERO_COUNT figures are picked.
local function selectHeroDefs(): { any }
	local defs: { any } = {}
	for index = #RarityTable.RARITY_ORDER, 1, -1 do
		local rarity = RarityTable.RARITY_ORDER[index]
		for _, def in RarityTable.GetPoolByRarity(rarity) do
			if #defs < HERO_COUNT then
				table.insert(defs, def)
			end
		end
		if #defs >= HERO_COUNT then
			break
		end
	end
	-- The walk above is rarest-first (defs[1] = rarest). The middle plinth
	-- (HERO_OFFSETS[2], the arc apex) is the showcase slot, so swap the
	-- rarest into index 2 (Addendum 2 R3-1 "best item framed at back");
	-- HeroIndex attrs stay positional 1..3 — client phase is slot-based.
	if #defs >= 2 then
		defs[1], defs[2] = defs[2], defs[1]
	end
	return defs
end

local function makeRecipePart(parent: Instance, shape: string, size: Vector3, cframe: CFrame, color: Color3): BasePart
	if shape == "Wedge" then
		return PartKit.MakeWedge(parent, "FigurePart", size, cframe, { color = color, decor = true })
	end
	local part = PartKit.MakePart(parent, "FigurePart", size, cframe, { color = color, decor = true })
	if shape == "Ball" then
		part.Shape = Enum.PartType.Ball
	elseif shape == "Cylinder" then
		part.Shape = Enum.PartType.Cylinder
	end
	return part
end

-- One oversized hero: plinth + Neon rarity ring + static recipe figure.
-- Tagged "HeroFigure" with CryptlingId / Rarity / HeroIndex attributes so
-- HeroFXController can spin and dress it client-side (Addendum 1 Change 3;
-- the 120-degree phase derives from HeroIndex). `baseCFrame` sits on the
-- plaza floor with -Z (front) facing the pad.
local function buildHero(parent: Model, def: any, baseCFrame: CFrame, heroIndex: number): Model
	local hero = Instance.new("Model")
	hero.Name = `Hero_{def.id}`

	local heroConfig = LobbyConfig.HERO
	local rarityColor: Color3 = (RarityTable.RARITY_COLORS :: any)[def.rarity] or COLOR_PLINTH
	local basePosition = baseCFrame.Position

	-- Scale: the def's own ladder times the hero multiplier, clamped so no
	-- figure towers past HERO_MAX_HEIGHT. The same recipe walk measures the
	-- per-figure XZ footprint, which drives the rarity-ring diameter
	-- (footprint x HERO.RING_FOOTPRINT_FACTOR — the guaranteed read).
	local scale = HERO_SCALE * (if type(def.scale) == "number" and def.scale > 0 then def.scale else 1)
	local tallest = 0
	local halfFootprint = 0
	for _, recipePart in def.recipe :: { any } do
		local ok, top, halfXZ = pcall(function()
			local offset = recipePart.offset :: CFrame
			local size = recipePart.size :: Vector3
			return offset.Position.Y + size.Y / 2,
				math.max(math.abs(offset.Position.X) + size.X / 2, math.abs(offset.Position.Z) + size.Z / 2)
		end)
		if ok and type(top) == "number" and type(halfXZ) == "number" then
			tallest = math.max(tallest, top)
			halfFootprint = math.max(halfFootprint, halfXZ)
		end
	end
	if tallest > 0 and tallest * scale > HERO_MAX_HEIGHT then
		scale = HERO_MAX_HEIGHT / tallest
	end
	local footprint = 2 * halfFootprint * scale
	local ringDiameter = (if footprint > 0 then footprint else HERO_PLINTH_DIAMETER) * heroConfig.RING_FOOTPRINT_FACTOR

	PartKit.MakeUprightCylinder(
		hero,
		"HeroPlinth",
		HERO_PLINTH_HEIGHT,
		HERO_PLINTH_DIAMETER,
		basePosition + Vector3.new(0, HERO_PLINTH_HEIGHT / 2, 0),
		{ color = COLOR_PLINTH }
	)
	PartKit.MakeUprightCylinder(
		hero,
		"HeroRing",
		heroConfig.RING_HEIGHT,
		ringDiameter,
		basePosition + Vector3.new(0, HERO_PLINTH_HEIGHT + heroConfig.RING_HEIGHT / 2, 0),
		{
			color = rarityColor,
			material = Enum.Material.Neon,
			transparency = heroConfig.RING_TRANSPARENCY,
			decor = true,
		}
	)

	local figure = Instance.new("Model")
	figure.Name = "Figure"
	local figureBase = baseCFrame * CFrame.new(0, HERO_PLINTH_HEIGHT + heroConfig.RING_HEIGHT, 0)
	for _, recipePart in def.recipe :: { any } do
		local offset = recipePart.offset :: CFrame
		local scaledOffset = CFrame.new(offset.Position * scale) * offset.Rotation
		makeRecipePart(
			figure,
			recipePart.shape :: string,
			(recipePart.size :: Vector3) * scale,
			figureBase * scaledOffset,
			(recipePart.colorOverride :: Color3?) or (def.color :: Color3)
		)
	end
	figure.WorldPivot = figureBase
	figure.Parent = hero

	-- Upright pivot at the podium base so the client spin (PivotTo yaw) never
	-- inherits the plinth cylinder's 90-degree roll; no PrimaryPart on purpose.
	hero.WorldPivot = baseCFrame
	hero:SetAttribute("CryptlingId", def.id)
	hero:SetAttribute("Rarity", def.rarity)
	hero:SetAttribute("HeroIndex", heroIndex)
	CollectionService:AddTag(hero, TAG_HERO)
	hero.Parent = parent
	return hero
end

--------------------------------------------------------------------------------
-- Build
--------------------------------------------------------------------------------

function WallBuilder.Build(parent: Model, origin: Vector3): WallBuild
	local model = Instance.new("Model")
	model.Name = "BrainrotWall"

	local function rel(x: number, y: number, z: number): Vector3
		return origin + Vector3.new(x, y, z)
	end

	local wallWidth = LobbyConfig.BRAINROT_WALL.WIDTH_STUDS
	local wallHeight = LobbyConfig.BRAINROT_WALL.HEIGHT_STUDS
	local wallCenterY = WALL_BOTTOM_Y + wallHeight / 2
	-- Front face west toward the pad; east face 0.05 studs proud of the
	-- facade plane (yaw +90 maps the part's width onto world Z).
	local facadeMount = CFrame.Angles(0, math.rad(90), 0)
	local slabCenterX = FACADE_X - 0.05 - WALL_THICKNESS / 2

	-- The slab BrainrotWallUI adorns (tagged; client builds the card grid).
	local wallPart = PartKit.MakePart(
		model,
		"WallSlab",
		Vector3.new(wallWidth, wallHeight, WALL_THICKNESS),
		CFrame.new(rel(slabCenterX, wallCenterY, 0)) * facadeMount,
		{ color = COLOR_SLAB }
	)
	CollectionService:AddTag(wallPart, TAG_WALL)

	-- Header board: the Addendum 1 Change 7 verbatim strip above the slab.
	local headerBoard = PartKit.MakePart(
		model,
		"WallHeader",
		Vector3.new(wallWidth + 2, HEADER_HEIGHT, WALL_THICKNESS),
		CFrame.new(rel(slabCenterX, WALL_BOTTOM_Y + wallHeight + HEADER_HEIGHT / 2, 0)) * facadeMount,
		{ color = COLOR_HEADER_BOARD, decor = true }
	)
	local headerGui = PartKit.MakeSurfaceGui(headerBoard, "WallHeaderGui")
	local headerLabel =
		PartKit.MakeLabel(headerGui, "HeaderLabel", HEADER_TEXT, UDim2.fromScale(0, 0), UDim2.fromScale(1, 1))

	-- Thin Neon trim strips in the Factory's amber accent (one accent hue per
	-- building, SOP §11.5), top and bottom of the slab.
	local trimColor = toColor3(LobbyConfig.MARQUEE_COLORS.FACTORY)
	for _, trimY in { WALL_BOTTOM_Y - 0.2, WALL_BOTTOM_Y + wallHeight + 0.2 } do
		PartKit.MakePart(
			model,
			"WallTrim",
			Vector3.new(wallWidth + 2, 0.4, 0.3),
			CFrame.new(rel(FACADE_X - 0.2, trimY, 0)) * facadeMount,
			{ color = trimColor, material = Enum.Material.Neon, decor = true }
		)
	end

	-- ONE SurfaceLight washes the wall (SOP §7: Range 16, Brightness 1,
	-- Angle 60) from a fixture bar above and in front, struts back to the
	-- facade. Registered against the PartKit light budget tally.
	local fixtureBar = PartKit.MakePart(
		model,
		"WallLightBar",
		Vector3.new(1.2, 0.6, wallWidth + 2),
		CFrame.new(rel(FACADE_X - 4, WALL_BOTTOM_Y + wallHeight + HEADER_HEIGHT + 0.5, 0)),
		{ color = COLOR_HEADER_BOARD, decor = true }
	)
	for _, strutZ in { -wallWidth / 2 + 4, wallWidth / 2 - 4 } do
		PartKit.MakePart(
			model,
			"WallLightStrut",
			Vector3.new(4, 0.4, 0.4),
			CFrame.new(rel(FACADE_X - 2, WALL_BOTTOM_Y + wallHeight + HEADER_HEIGHT + 0.5, strutZ)),
			{ color = COLOR_HEADER_BOARD, decor = true }
		)
	end
	local surfaceLight = Instance.new("SurfaceLight")
	surfaceLight.Face = Enum.NormalId.Bottom
	surfaceLight.Angle = LobbyConfig.BRAINROT_WALL.LIGHT_ANGLE
	surfaceLight.Range = LobbyConfig.BRAINROT_WALL.LIGHT_RANGE
	surfaceLight.Brightness = LobbyConfig.BRAINROT_WALL.LIGHT_BRIGHTNESS
	surfaceLight.Color = COLOR_LIGHT_COOL
	surfaceLight.Shadows = false
	surfaceLight.Parent = fixtureBar
	PartKit.LightBudget.Register(surfaceLight)

	-- Hero podium figures of the rarest rotation Cryptlings, facing the pad
	-- (static here; HeroFXController spins them client-side off HeroIndex).
	local padCenter = rel(FACADE_X - 26, 0, 0)
	local heroDefs = selectHeroDefs()
	local heroFigures: { Model } = {}
	for index, def in heroDefs do
		local offset = HERO_OFFSETS[((index - 1) % #HERO_OFFSETS) + 1]
		local basePosition = rel(FACADE_X + offset.X, 0, offset.Z)
		local baseCFrame = CFrame.lookAt(basePosition, Vector3.new(padCenter.X, basePosition.Y, padCenter.Z))
		table.insert(heroFigures, buildHero(model, def, baseCFrame, index))
	end

	model.Parent = parent

	return {
		model = model,
		wallPart = wallPart,
		headerLabel = headerLabel,
		surfaceLight = surfaceLight,
		heroFigures = heroFigures,
	}
end

return WallBuilder
