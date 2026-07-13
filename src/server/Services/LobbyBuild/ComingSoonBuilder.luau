--!strict
-- CRYPTLINGS: NIGHT SHIFT — ComingSoonBuilder: the large derelict building
-- capping the street's WEST end (LOBBY_SOP §1.4, §9 flicker, §11.1 marquee
-- rules, §11.4 silhouette goal-post). Pure construction by contract: no
-- signals, no loops over time, no player logic, no Init/Start — HubService
-- invokes Build() once at boot with the lobby model and HUB_ORIGIN.
--
-- The flicker LOOP lives in HubService (Wave 3), NOT here: Build() returns
-- `flickerParts` — the "Coming Soon" Neon letter parts — and HubService
-- toggles their Material Neon <-> SmoothPlastic on the LobbyConfig
-- COMING_SOON_FLICKER cadence.
--
-- Silhouette: the body stands 60 studs tall (SOP requires >= 55) so it
-- reads as the street's goal-post through the Atmosphere haze from the
-- Factory end. Sparse lit windows (deterministic pattern) plus ONE budgeted
-- feature light (SOP §2.6 "Coming Soon x1") — a dim façade uplight.
--
-- Coordinates: street axis = X, Factory at the east end (build-plan
-- convention). The Coming Soon façade plane caps the corridor at
-- -(lotSpan/2 + forecourt depth); the body extends west behind it.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local LobbyConfig = require(Shared:WaitForChild("Config"):WaitForChild("LobbyConfig"))

local PartKit = require(script.Parent:WaitForChild("PartKit"))

--------------------------------------------------------------------------------
-- Layout (derived from LobbyConfig; no magic street numbers)
--------------------------------------------------------------------------------

local LOT_SPAN_X = LobbyConfig.LOTS_PER_SIDE * (LobbyConfig.LOT_FRONTAGE_STUDS + LobbyConfig.LOT_GAP_STUDS) -- 530
local FRONT_X = -(LOT_SPAN_X / 2 + LobbyConfig.COMING_SOON_FORECOURT_DEPTH_STUDS) -- -345: façade plane

-- Build-local greybox dimensions (level-art only; nothing else reads these).
local BODY_DEPTH_X = 40
local BODY_WIDTH_Z = 100 -- wider than the 56-stud corridor: caps the end wall-to-wall
local BODY_HEIGHT = 60 -- SOP silhouette rule: >= 55
local WINDOW_ROWS_Y = { 10, 19, 28 } -- below the marquee letters
local WINDOW_COLS_Z = { -42, -30, -18, -6, 6, 18, 30, 42 }
local WINDOW_LIT_CHANCE = 0.28 -- sparse: roughly a quarter glow
local WINDOW_SEED = 0x50C1A1 -- deterministic pattern, same every boot

-- Night greybox palette (the marquee color comes from LobbyConfig).
local COLOR_BODY = Color3.fromRGB(44, 42, 52)
local COLOR_ROOF_BLOCK = Color3.fromRGB(36, 34, 44)
local COLOR_DOOR = Color3.fromRGB(30, 28, 34)
local COLOR_WINDOW_DARK = Color3.fromRGB(24, 26, 34)
local COLOR_WINDOW_LIT = Color3.fromRGB(120, 140, 190)

local function toColor(rgbTable: { R: number, G: number, B: number }): Color3
	return Color3.fromRGB(rgbTable.R, rgbTable.G, rgbTable.B)
end

--------------------------------------------------------------------------------
-- ComingSoonBuilder
--------------------------------------------------------------------------------

local ComingSoonBuilder = {}

export type ComingSoonBuild = {
	flickerParts: { BasePart },
}

function ComingSoonBuilder.Build(parent: Model, origin: Vector3): ComingSoonBuild
	local function at(x: number, y: number, z: number): Vector3
		return origin + Vector3.new(x, y, z)
	end

	local tower = Instance.new("Model")
	tower.Name = "ComingSoonBuilding"

	-- Body block caps the corridor (collidable boundary at this end) plus a
	-- stepped rooftop block for an irregular night silhouette.
	PartKit.MakePart(
		tower,
		"ComingSoonBody",
		Vector3.new(BODY_DEPTH_X, BODY_HEIGHT, BODY_WIDTH_Z),
		CFrame.new(at(FRONT_X - BODY_DEPTH_X / 2, BODY_HEIGHT / 2, 0)),
		{ color = COLOR_BODY }
	)
	PartKit.MakePart(
		tower,
		"ComingSoonRoofBlock",
		Vector3.new(24, 8, 70),
		CFrame.new(at(FRONT_X - 23, BODY_HEIGHT + 4, 0)),
		{ color = COLOR_ROOF_BLOCK }
	)

	-- Boarded entrance slab, proud of the façade (no z-fighting, SOP §11.2).
	PartKit.MakePart(tower, "ComingSoonDoor", Vector3.new(0.4, 14, 12), CFrame.new(at(FRONT_X + 0.3, 7, 0)), {
		color = COLOR_DOOR,
		decor = true,
	})

	-- Sparse lit windows: deterministic pattern (fixed seed) so every server
	-- renders the same derelict face. Lit panes are Neon; dark panes plain.
	local rng = Random.new(WINDOW_SEED)
	for _, y in WINDOW_ROWS_Y do
		for _, z in WINDOW_COLS_Z do
			local lit = rng:NextNumber() < WINDOW_LIT_CHANCE
			PartKit.MakePart(tower, "ComingSoonWindow", Vector3.new(0.3, 4, 3), CFrame.new(at(FRONT_X + 0.25, y, z)), {
				color = if lit then COLOR_WINDOW_LIT else COLOR_WINDOW_DARK,
				material = if lit then Enum.Material.Neon else Enum.Material.SmoothPlastic,
				transparency = if lit then 0.1 else 0,
				decor = true,
			})
		end
	end

	-- "Coming Soon" marquee (verbatim string): dim-white Neon block letters,
	-- proud of the façade, facing east down the street. The letter CFrame's
	-- LookVector points the street viewer's gaze direction (-X) so the
	-- string reads left-to-right from the Factory end.
	local lettersCenter = at(FRONT_X + 1, 44, 0)
	local letters = PartKit.MakeBlockLetters(
		tower,
		"Coming Soon",
		CFrame.lookAt(lettersCenter, lettersCenter + Vector3.new(-1, 0, 0)),
		LobbyConfig.MARQUEE_LETTER_HEIGHT_STUDS,
		toColor(LobbyConfig.MARQUEE_COLORS.COMING_SOON)
	)

	-- The building's one budgeted feature light (SOP §2.6): a dim uplight
	-- stanchion in the forecourt washing the façade and letters. Registered
	-- via PartKit.MakeSpot (Shadows=false + light-budget tally).
	local uplight = PartKit.MakePart(
		tower,
		"ComingSoonUplight",
		Vector3.new(1.5, 1, 1.5),
		CFrame.new(at(FRONT_X + 5, 0.5, 0)),
		{ color = COLOR_ROOF_BLOCK, decor = true }
	)
	PartKit.MakeSpot(uplight, {
		angle = 42,
		range = 50,
		brightness = 1.2,
		color = toColor(LobbyConfig.MARQUEE_COLORS.COMING_SOON),
		face = Enum.NormalId.Top,
	})

	tower.Parent = parent
	return { flickerParts = letters.parts }
end

return ComingSoonBuilder
