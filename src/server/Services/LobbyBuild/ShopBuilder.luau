--!strict
-- CRYPTLINGS: NIGHT SHIFT — ShopBuilder: the Shop building on the Factory
-- plaza's south side (LOBBY_SOP §1.3 plaza, §8 dual-anchor building, §11.1
-- marquee rules). Pure construction by contract: no signals, no loops over
-- time, no player logic, no Init/Start — HubService invokes Build() once at
-- boot with the lobby model and HUB_ORIGIN.
--
-- Preserved contract: the storefront counter Part is tagged "ShopKiosk".
-- ShopUI attaches its client-local ProximityPrompt to that tag (SOP §8 —
-- opening the shop needs no remote and no server prompt), so the counter
-- must stay collidable/queryable and reachable from the doorway.
--
-- Marquee: extruded "Shop" Neon block letters (cyan, LobbyConfig
-- MARQUEE_COLORS.SHOP) via PartKit.MakeBlockLetters on a dark backing board
-- over the storefront, plus a neon trim strip carrying the shop's ONE
-- feature light (SOP §2.6 budget line "shop neon x1").
--
-- Coordinates: street axis = X, Factory at the east end (build-plan
-- convention). The lot frontage spans LOTS_PER_SIDE * (frontage + gap)
-- studs centered on the origin; the Factory plaza runs east from its edge,
-- and the shop fronts the plaza from the south (-Z), door facing north.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local LobbyConfig = require(Shared:WaitForChild("Config"):WaitForChild("LobbyConfig"))

local PartKit = require(script.Parent:WaitForChild("PartKit"))

--------------------------------------------------------------------------------
-- Layout (derived from LobbyConfig; no magic street numbers)
--------------------------------------------------------------------------------

local LOT_SPAN_X = LobbyConfig.LOTS_PER_SIDE * (LobbyConfig.LOT_FRONTAGE_STUDS + LobbyConfig.LOT_GAP_STUDS) -- 530
local PLAZA_WEST_X = LOT_SPAN_X / 2 -- 265: west edge of the Factory plaza

-- Build-local greybox dimensions (level-art only; nothing else reads these).
local SHOP_CENTER_X = PLAZA_WEST_X + 65 -- mid-plaza, clear of the queue pad lane
local SHOP_FRONT_Z = -40 -- storefront wall plane; door faces north (+Z)
local SHOP_WIDTH_X = 28
local SHOP_DEPTH_Z = 22
local WALL_HEIGHT = 12
local WALL_THICKNESS = 1.4
local DOOR_WIDTH = 8
local DOOR_HEIGHT = 8

-- Night greybox palette (thematic accents come from LobbyConfig).
local COLOR_WALL = Color3.fromRGB(56, 54, 64)
local COLOR_ROOF = Color3.fromRGB(40, 38, 46)
local COLOR_FLOOR = Color3.fromRGB(64, 58, 52)
local COLOR_COUNTER = Color3.fromRGB(120, 90, 60)
local COLOR_DARK_BOARD = Color3.fromRGB(24, 22, 28)
local COLOR_WINDOW_GLOW = Color3.fromRGB(140, 190, 255)

local function toColor(rgbTable: { R: number, G: number, B: number }): Color3
	return Color3.fromRGB(rgbTable.R, rgbTable.G, rgbTable.B)
end

--------------------------------------------------------------------------------
-- ShopBuilder
--------------------------------------------------------------------------------

local ShopBuilder = {}

export type ShopBuild = {
	counter: BasePart,
}

function ShopBuilder.Build(parent: Model, origin: Vector3): ShopBuild
	local function at(x: number, y: number, z: number): Vector3
		return origin + Vector3.new(x, y, z)
	end

	local shop = Instance.new("Model")
	shop.Name = "ShopBuilding"

	local cx = SHOP_CENTER_X
	local cz = SHOP_FRONT_Z - SHOP_DEPTH_Z / 2 -- building center, behind the storefront
	local flankWidth = (SHOP_WIDTH_X - DOOR_WIDTH) / 2

	-- Shell: floor, four walls (north wall split around the door), roof.
	PartKit.MakePart(shop, "ShopFloor", Vector3.new(SHOP_WIDTH_X, 0.5, SHOP_DEPTH_Z), CFrame.new(at(cx, 0.25, cz)), {
		color = COLOR_FLOOR,
	})
	PartKit.MakePart(
		shop,
		"ShopWallNW",
		Vector3.new(flankWidth, WALL_HEIGHT, WALL_THICKNESS),
		CFrame.new(at(cx - (DOOR_WIDTH + flankWidth) / 2, WALL_HEIGHT / 2, SHOP_FRONT_Z)),
		{ color = COLOR_WALL }
	)
	PartKit.MakePart(
		shop,
		"ShopWallNE",
		Vector3.new(flankWidth, WALL_HEIGHT, WALL_THICKNESS),
		CFrame.new(at(cx + (DOOR_WIDTH + flankWidth) / 2, WALL_HEIGHT / 2, SHOP_FRONT_Z)),
		{ color = COLOR_WALL }
	)
	PartKit.MakePart(
		shop,
		"ShopWallNLintel",
		Vector3.new(DOOR_WIDTH, WALL_HEIGHT - DOOR_HEIGHT, WALL_THICKNESS),
		CFrame.new(at(cx, (WALL_HEIGHT + DOOR_HEIGHT) / 2, SHOP_FRONT_Z)),
		{ color = COLOR_WALL }
	)
	PartKit.MakePart(
		shop,
		"ShopWallS",
		Vector3.new(SHOP_WIDTH_X, WALL_HEIGHT, WALL_THICKNESS),
		CFrame.new(at(cx, WALL_HEIGHT / 2, SHOP_FRONT_Z - SHOP_DEPTH_Z)),
		{ color = COLOR_WALL }
	)
	PartKit.MakePart(
		shop,
		"ShopWallW",
		Vector3.new(WALL_THICKNESS, WALL_HEIGHT, SHOP_DEPTH_Z),
		CFrame.new(at(cx - SHOP_WIDTH_X / 2, WALL_HEIGHT / 2, cz)),
		{ color = COLOR_WALL }
	)
	PartKit.MakePart(
		shop,
		"ShopWallE",
		Vector3.new(WALL_THICKNESS, WALL_HEIGHT, SHOP_DEPTH_Z),
		CFrame.new(at(cx + SHOP_WIDTH_X / 2, WALL_HEIGHT / 2, cz)),
		{ color = COLOR_WALL }
	)
	PartKit.MakePart(
		shop,
		"ShopRoof",
		Vector3.new(SHOP_WIDTH_X + 2, 1, SHOP_DEPTH_Z + 2),
		CFrame.new(at(cx, WALL_HEIGHT + 0.5, cz)),
		{ color = COLOR_ROOF }
	)

	-- Window glow strips flanking the door (night storefront read, SOP §1.4).
	-- Proud of the exterior wall face so nothing z-fights (SOP §11.2).
	for index, x in { cx - (DOOR_WIDTH + flankWidth) / 2, cx + (DOOR_WIDTH + flankWidth) / 2 } do
		PartKit.MakePart(
			shop,
			`ShopWindow{index}`,
			Vector3.new(6, 4, 0.3),
			CFrame.new(at(x, 5.5, SHOP_FRONT_Z + WALL_THICKNESS / 2 + 0.2)),
			{ color = COLOR_WINDOW_GLOW, material = Enum.Material.Neon, transparency = 0.25, decor = true }
		)
	end

	-- Interior neon ceiling strip — visual fill only, NOT a Light instance
	-- (the shop's single budgeted feature light lives on the marquee trim).
	PartKit.MakePart(shop, "ShopCeilingStrip", Vector3.new(16, 0.3, 1), CFrame.new(at(cx, WALL_HEIGHT - 0.4, cz)), {
		color = toColor(LobbyConfig.MARQUEE_COLORS.SHOP),
		material = Enum.Material.Neon,
		decor = true,
	})

	-- Storefront counter just inside the doorway: the tagged "ShopKiosk"
	-- part. ShopUI's client-local ProximityPrompt (MaxActivationDistance per
	-- LobbyConfig.SHOP_PROMPT_DISTANCE_STUDS) reaches it from the door, so it
	-- stays collidable and queryable — never decor-flagged.
	local counter = PartKit.MakePart(
		shop,
		"ShopCounter",
		Vector3.new(10, 3.4, 2.4),
		CFrame.new(at(cx, 0.5 + 1.7, SHOP_FRONT_Z - 3.5)),
		{ color = COLOR_COUNTER }
	)
	CollectionService:AddTag(counter, "ShopKiosk")
	PartKit.MakePart(
		shop,
		"ShopCounterTop",
		Vector3.new(10.8, 0.4, 3.2),
		CFrame.new(at(cx, 0.5 + 3.4 + 0.2, SHOP_FRONT_Z - 3.5)),
		{ color = COLOR_DARK_BOARD }
	)

	-- Rooftop marquee: dark backing board continuing the storefront plane,
	-- extruded Neon "Shop" block letters in front of it, neon trim strip
	-- underneath. Letters face north (+Z, toward the plaza): the string runs
	-- left-to-right for a viewer on the plaza looking south, so the letter
	-- CFrame's LookVector points the viewer's gaze direction (-Z).
	local letterHeight = LobbyConfig.MARQUEE_LETTER_HEIGHT_STUDS
	local backingHeight = letterHeight + 2
	PartKit.MakePart(
		shop,
		"ShopMarqueeBacking",
		Vector3.new(SHOP_WIDTH_X - 2, backingHeight, 1),
		CFrame.new(at(cx, WALL_HEIGHT + 0.5 + backingHeight / 2, SHOP_FRONT_Z)),
		{ color = COLOR_DARK_BOARD, decor = true }
	)
	local lettersCenter = at(cx, WALL_HEIGHT + 0.5 + backingHeight / 2, SHOP_FRONT_Z + 1.3)
	PartKit.MakeBlockLetters(
		shop,
		"Shop",
		CFrame.lookAt(lettersCenter, lettersCenter + Vector3.new(0, 0, -1)),
		letterHeight,
		toColor(LobbyConfig.MARQUEE_COLORS.SHOP)
	)

	local trim = PartKit.MakePart(
		shop,
		"ShopNeonTrim",
		Vector3.new(SHOP_WIDTH_X - 2, 0.4, 0.5),
		CFrame.new(at(cx, WALL_HEIGHT + 0.9, SHOP_FRONT_Z + 1)),
		{ color = toColor(LobbyConfig.MARQUEE_COLORS.SHOP), material = Enum.Material.Neon, decor = true }
	)
	-- The shop's one feature light (SOP §2.6) — registered via PartKit so the
	-- HubService light-budget assert counts it.
	PartKit.MakePoint(trim, { range = 24, brightness = 0.9, color = toColor(LobbyConfig.MARQUEE_COLORS.SHOP) })

	shop.Parent = parent
	return { counter = counter :: BasePart }
end

return ShopBuilder
