--!strict
-- CRYPTLINGS: NIGHT SHIFT — PlazaBuilder: Factory-plaza fixtures (LOBBY_SOP
-- §1.3, §9). Pure construction by contract: no signals, no loops over time,
-- no player logic, no Init/Start — HubService invokes Build() once at boot
-- with the lobby model and HUB_ORIGIN.
--
-- Preserved contracts (byte-for-byte names/tags — see the build plan's
-- contract table):
--   * Unbox stage Model named "UnboxStage" with children named exactly
--     "UnboxPedestal", "ConfettiAnchor", and "StageSpotlight" (SpotLight
--     Angle 46 / Brightness 3 / Range 22) — UnboxingUI's theater and
--     HubService.GetUnboxStage() depend on these names.
--   * Two facing swap-meet pads tagged "TradePad" with attribute
--     PadIndex = 1/2 — TradeUI's pad poll and TradeService.isOnTradePad
--     read the tag, the positions, and the pad sizes.
--
-- Swap-meet kit (Addendum 1 Change 5): Neon trim strips on both trade pads
-- and on the stall frames (decor-flagged, zero Light cost); overhead beacon
-- over the pad midpoint — steel pole, 2x2x2 Neon head built WHITE at
-- SWAP_BEACON.HEAD_HEIGHT and tagged "SwapMeetBeacon" (TradeService stamps
-- the TradeActive attribute on it; TradeBeaconController owns every tween
-- client-side), plus the Neon pillar clone of the QueuePadBuilder beacon
-- idiom. The ONE relocated feature light — the retired fountain PointLight's
-- budget slot (Change 8) — is a PartKit.MakeSpot on a stall-frame mount aimed
-- at the trade deck (warm white, Shadows=false, self-registers in
-- LightBudget): the feature census stays 8 and the lobby total stays 50.
--
-- Benches are decor-flagged (SOP §10 display preset) and placed at the
-- plaza edges, clear of the queue-pad approach lane down the plaza center.
--
-- Coordinates: street axis = X, Factory at the east end (build-plan
-- convention). The Factory plaza runs east from the lot span's edge; the
-- unbox stage sits south of center, the swap meet north, mirroring the old
-- hub's north/south split so neither crowds the queue pad.

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
local STAGE_X = PLAZA_WEST_X + 23 -- south-of-center plaza, west of the shop
local STAGE_Z = -34
local SWAP_X = PLAZA_WEST_X + 25 -- north plaza corner
local SWAP_Z = 34
local PAD_GAP_Z = 12 -- facing trade pads, centers this far apart

-- Preserved StageSpotlight rig values (Angle 46 / Brightness 3 / Range 22).
local STAGE_SPOT_ANGLE = 46
local STAGE_SPOT_BRIGHTNESS = 3
local STAGE_SPOT_RANGE = 22

-- Swap-meet stall spot (Addendum 1 Change 5/8): the fountain PointLight's
-- reassigned feature-light slot, aimed from the north stall header at the
-- trade deck. Build-local rig values, same idiom as the stage spot above.
local SWAP_SPOT_ANGLE = 75
local SWAP_SPOT_BRIGHTNESS = 1.6
local SWAP_SPOT_RANGE = 26

-- Stall-frame greybox dimensions (level-art only).
local STALL_X_OFFSET = 11 -- stall line east of the deck center
local STALL_Z_OFFSET = 7 -- two stalls, north/south of the deck center
local STALL_WIDTH_Z = 7
local STALL_POST_HEIGHT = 6.5
local STALL_HEADER_Y = 6.9

-- Night greybox palette.
local COLOR_STAGE = Color3.fromRGB(60, 58, 66)
local COLOR_HAZARD = Color3.fromRGB(235, 190, 52)
local COLOR_STEEL = Color3.fromRGB(120, 124, 132)
local COLOR_WOOD = Color3.fromRGB(120, 90, 60)
local COLOR_SIGN_BOARD = Color3.fromRGB(24, 22, 28)
local COLOR_ARROW = Color3.fromRGB(80, 220, 120)
local COLOR_SPOT_WARM = Color3.fromRGB(255, 236, 200)
local COLOR_SIGN_SUBTEXT = Color3.fromRGB(170, 170, 170)
local COLOR_TRIM_WHITE = Color3.fromRGB(255, 250, 240) -- swap-meet Neon trim
local COLOR_CANOPY = Color3.fromRGB(70, 66, 78)

--------------------------------------------------------------------------------
-- Local builders
--------------------------------------------------------------------------------

-- Unbox stage: dais + pedestal + confetti anchor + spotlight rig. Child
-- names are the preserved UnboxingUI/HubService contract.
local function buildUnboxStage(parent: Model, at: (number, number, number) -> Vector3): Model
	local stage = Instance.new("Model")
	stage.Name = "UnboxStage"

	PartKit.MakeUprightCylinder(stage, "StageDais", 1, 15, at(STAGE_X, 0.5, STAGE_Z), { color = COLOR_STAGE })
	PartKit.MakeUprightCylinder(stage, "UnboxPedestal", 3, 3.5, at(STAGE_X, 2.5, STAGE_Z), { color = COLOR_HAZARD })

	-- Step up the dais lip from the plaza side (north); the wedge's tall
	-- face turns toward the dais so the slope rises southward.
	PartKit.MakeWedge(
		stage,
		"StageStep",
		Vector3.new(6, 1, 3),
		CFrame.new(at(STAGE_X, 0.5, STAGE_Z + 9)) * CFrame.Angles(0, math.rad(180), 0),
		{ color = COLOR_STAGE }
	)

	PartKit.MakePart(stage, "ConfettiAnchor", Vector3.new(1, 1, 1), CFrame.new(at(STAGE_X, 9, STAGE_Z)), {
		transparency = 1,
		decor = true,
	})

	-- Spotlight rig on a pole; the SpotLight goes through PartKit.MakeSpot so
	-- Shadows=false is enforced and the light registers against the budget.
	PartKit.MakeUprightCylinder(stage, "StagePole", 14, 0.6, at(STAGE_X + 7, 7, STAGE_Z), { color = COLOR_STEEL })
	local rig =
		PartKit.MakePart(stage, "StageSpotlight", Vector3.new(2, 1, 2), CFrame.new(at(STAGE_X + 4, 13.4, STAGE_Z)), {
			color = COLOR_SIGN_BOARD,
			canCollide = false,
		})
	PartKit.MakeSpot(rig, {
		angle = STAGE_SPOT_ANGLE,
		range = STAGE_SPOT_RANGE,
		brightness = STAGE_SPOT_BRIGHTNESS,
		color = COLOR_SPOT_WARM,
	})

	stage.Parent = parent
	return stage
end

-- Neon trim frame around a horizontal rectangular footprint (zero Light
-- cost — Change 5 "further illuminated" path). Strips straddle the edge.
local function buildNeonTrim(
	parent: Model,
	name: string,
	center: Vector3,
	sizeX: number,
	sizeZ: number,
	strip: number,
	height: number
)
	local props: PartKit.PartProps =
		{ color = COLOR_TRIM_WHITE, material = Enum.Material.Neon, transparency = 0.15, decor = true }
	for _, zSign in { -1, 1 } do
		PartKit.MakePart(
			parent,
			name,
			Vector3.new(sizeX + strip * 2, height, strip),
			CFrame.new(center + Vector3.new(0, 0, zSign * (sizeZ + strip) / 2)),
			props
		)
	end
	for _, xSign in { -1, 1 } do
		PartKit.MakePart(
			parent,
			name,
			Vector3.new(strip, height, sizeZ),
			CFrame.new(center + Vector3.new(xSign * (sizeX + strip) / 2, 0, 0)),
			props
		)
	end
end

-- One market-stall frame east of the trade deck, facing west toward it:
-- two posts, header beam, canopy slab, counter, and a Neon trim strip under
-- the header (all decor-flagged). The swap-meet spot mounts beside the north
-- stall's header (built separately in buildSwapMeet).
local function buildStallFrame(parent: Model, at: (number, number, number) -> Vector3, zCenter: number)
	local props: PartKit.PartProps = { color = COLOR_STEEL, decor = true }
	for _, zSign in { -1, 1 } do
		PartKit.MakePart(
			parent,
			"StallPost",
			Vector3.new(0.5, STALL_POST_HEIGHT, 0.5),
			CFrame.new(at(SWAP_X + STALL_X_OFFSET, STALL_POST_HEIGHT / 2, zCenter + zSign * STALL_WIDTH_Z / 2)),
			props
		)
	end
	PartKit.MakePart(
		parent,
		"StallHeader",
		Vector3.new(0.6, 0.8, STALL_WIDTH_Z + 0.5),
		CFrame.new(at(SWAP_X + STALL_X_OFFSET, STALL_HEADER_Y, zCenter)),
		props
	)
	PartKit.MakePart(
		parent,
		"StallCanopy",
		Vector3.new(3.2, 0.3, STALL_WIDTH_Z + 1),
		CFrame.new(at(SWAP_X + STALL_X_OFFSET - 0.8, STALL_HEADER_Y + 0.55, zCenter)),
		{ color = COLOR_CANOPY, decor = true }
	)
	PartKit.MakePart(
		parent,
		"StallCounter",
		Vector3.new(2, 1, STALL_WIDTH_Z - 0.5),
		CFrame.new(at(SWAP_X + STALL_X_OFFSET - 0.6, 0.5, zCenter)),
		{ color = COLOR_WOOD, decor = true }
	)
	-- Stall-frame Neon trim strip under the header lip (Change 5).
	PartKit.MakePart(
		parent,
		"StallTrim",
		Vector3.new(0.15, 0.3, STALL_WIDTH_Z + 0.5),
		CFrame.new(at(SWAP_X + STALL_X_OFFSET - 0.4, STALL_HEADER_Y - 0.6, zCenter)),
		{ color = COLOR_TRIM_WHITE, material = Enum.Material.Neon, transparency = 0.15, decor = true }
	)
end

-- Swap-meet deck: two facing TradePads + cosmetic arrows + post sign +
-- Change 5 kit (pad/stall Neon trim, overhead beacon, relocated stall spot).
-- Returns the trade pads and the tagged beacon head.
local function buildSwapMeet(parent: Model, at: (number, number, number) -> Vector3): ({ BasePart }, BasePart)
	local corner = Instance.new("Model")
	corner.Name = "SwapMeet"

	PartKit.MakePart(
		corner,
		"SwapMeetDeck",
		Vector3.new(16, 0.4, PAD_GAP_Z + 10),
		CFrame.new(at(SWAP_X, 0.2, SWAP_Z)),
		{
			color = COLOR_WOOD,
		}
	)

	local tradePads: { BasePart } = {}
	local padDefs = {
		{ index = 1, z = SWAP_Z - PAD_GAP_Z / 2, arrowOffset = 3.5, arrowYaw = 180 }, -- south pad faces north
		{ index = 2, z = SWAP_Z + PAD_GAP_Z / 2, arrowOffset = -3.5, arrowYaw = 0 }, -- north pad faces south
	}
	for _, def in padDefs do
		local pad = PartKit.MakePart(
			corner,
			`TradePad{def.index}`,
			Vector3.new(6, 0.5, 6),
			CFrame.new(at(SWAP_X, 0.65, def.z)),
			{ color = COLOR_STEEL }
		)
		pad:SetAttribute("PadIndex", def.index)
		CollectionService:AddTag(pad, "TradePad")
		table.insert(tradePads, pad)

		-- Neon trim skirt framing the pad edge (Change 5, zero Light cost).
		buildNeonTrim(corner, "TradePadTrim", at(SWAP_X, 0.78, def.z), 6, 6, 0.4, 0.25)

		PartKit.MakeWedge(
			corner,
			`TradePadArrow{def.index}`,
			Vector3.new(1.5, 0.5, 1.5),
			CFrame.new(at(SWAP_X, 0.65, def.z + def.arrowOffset)) * CFrame.Angles(0, math.rad(def.arrowYaw), 0),
			{ color = COLOR_ARROW, decor = true }
		)
	end

	-- Post sign beside the deck, front face turned east toward the pads.
	PartKit.MakeUprightCylinder(corner, "SwapSignPost", 7, 0.5, at(SWAP_X - 10, 3.5, SWAP_Z), { color = COLOR_STEEL })
	local signPosition = at(SWAP_X - 10, 7.8, SWAP_Z)
	local sign = PartKit.MakePart(
		corner,
		"SwapMeetSign",
		Vector3.new(8, 2.6, 0.4),
		CFrame.lookAt(signPosition, signPosition + Vector3.new(1, 0, 0)),
		{ color = COLOR_SIGN_BOARD, decor = true }
	)
	local gui = PartKit.MakeSurfaceGui(sign, "SwapMeetSignGui")
	PartKit.MakeLabel(gui, "Line1", "SWAP MEET", UDim2.fromScale(0.05, 0.06), UDim2.fromScale(0.9, 0.52))
	PartKit.MakeLabel(
		gui,
		"Line2",
		"Stand on facing pads to trade — confirm twice",
		UDim2.fromScale(0.05, 0.6),
		UDim2.fromScale(0.9, 0.32),
		COLOR_SIGN_SUBTEXT
	)

	-- Two stall frames east of the deck, facing it (Change 5); the spot mount
	-- sits beside the north stall's header.
	buildStallFrame(corner, at, SWAP_Z - STALL_Z_OFFSET)
	buildStallFrame(corner, at, SWAP_Z + STALL_Z_OFFSET)

	-- The ONE relocated feature light (the fountain PointLight's freed slot,
	-- Change 5/8): PartKit.MakeSpot on a stall-frame mount aimed at the trade
	-- deck — warm white, Shadows=false enforced and self-registered against
	-- LightBudget by PartKit, so the feature census stays 8 and the lobby
	-- total stays exactly 50.
	local mountPosition = at(SWAP_X + STALL_X_OFFSET - 1, STALL_HEADER_Y + 0.7, SWAP_Z + STALL_Z_OFFSET)
	local deckCenter = at(SWAP_X, 0.4, SWAP_Z)
	local spotMount = PartKit.MakePart(
		corner,
		"SwapMeetSpotMount",
		Vector3.new(1.2, 0.8, 1.2),
		CFrame.lookAt(mountPosition, deckCenter),
		{ color = COLOR_SIGN_BOARD, decor = true }
	)
	PartKit.MakeSpot(spotMount, {
		angle = SWAP_SPOT_ANGLE,
		range = SWAP_SPOT_RANGE,
		brightness = SWAP_SPOT_BRIGHTNESS,
		color = COLOR_SPOT_WARM,
		face = Enum.NormalId.Front,
	})

	-- Overhead beacon over the pad midpoint (Change 5): steel pole, Neon
	-- pillar (QueuePadBuilder beacon idiom, standard FX flags), and the 2x2x2
	-- Neon head built WHITE — steady white = available per the andon
	-- convention; TradeService stamps TradeActive on the head and
	-- TradeBeaconController owns every green-pulse tween client-side.
	local deckTop = 0.4
	PartKit.MakeUprightCylinder(
		corner,
		"SwapBeaconPole",
		LobbyConfig.SWAP_BEACON.HEAD_HEIGHT,
		0.4,
		at(SWAP_X, deckTop + LobbyConfig.SWAP_BEACON.HEAD_HEIGHT / 2, SWAP_Z),
		{ color = COLOR_STEEL, decor = true }
	)
	PartKit.MakeUprightCylinder(
		corner,
		"SwapBeaconPillar",
		LobbyConfig.SWAP_BEACON.PILLAR_HEIGHT,
		LobbyConfig.SWAP_BEACON.PILLAR_DIAMETER,
		at(SWAP_X, deckTop + LobbyConfig.SWAP_BEACON.PILLAR_HEIGHT / 2, SWAP_Z),
		{
			color = Color3.fromRGB(
				LobbyConfig.SWAP_BEACON.IDLE_COLOR.R,
				LobbyConfig.SWAP_BEACON.IDLE_COLOR.G,
				LobbyConfig.SWAP_BEACON.IDLE_COLOR.B
			),
			material = Enum.Material.Neon,
			transparency = LobbyConfig.SWAP_BEACON.PILLAR_TRANSPARENCY,
			decor = true,
		}
	)
	local beaconHead = PartKit.MakePart(
		corner,
		"SwapBeaconHead",
		Vector3.new(
			LobbyConfig.SWAP_BEACON.HEAD_SIZE,
			LobbyConfig.SWAP_BEACON.HEAD_SIZE,
			LobbyConfig.SWAP_BEACON.HEAD_SIZE
		),
		CFrame.new(at(SWAP_X, deckTop + LobbyConfig.SWAP_BEACON.HEAD_HEIGHT, SWAP_Z)),
		{
			color = Color3.fromRGB(
				LobbyConfig.SWAP_BEACON.IDLE_COLOR.R,
				LobbyConfig.SWAP_BEACON.IDLE_COLOR.G,
				LobbyConfig.SWAP_BEACON.IDLE_COLOR.B
			),
			material = Enum.Material.Neon,
			decor = true,
		}
	)
	beaconHead.Shape = Enum.PartType.Ball
	CollectionService:AddTag(beaconHead, "SwapMeetBeacon")

	corner.Parent = parent
	return tradePads, beaconHead
end

-- One greybox bench: seat + back + two legs, all decor-flagged (SOP §10).
-- `yawDegrees` turns the bench's seating face; 0 faces -Z (south).
local function buildBench(parent: Model, position: Vector3, yawDegrees: number)
	local base = CFrame.new(position) * CFrame.Angles(0, math.rad(yawDegrees), 0)
	local props: PartKit.PartProps = { color = COLOR_WOOD, decor = true }
	PartKit.MakePart(parent, "BenchSeat", Vector3.new(5.5, 0.4, 1.8), base * CFrame.new(0, 1.5, 0), props)
	PartKit.MakePart(parent, "BenchBack", Vector3.new(5.5, 1.8, 0.3), base * CFrame.new(0, 2.3, 0.85), props)
	PartKit.MakePart(parent, "BenchLegW", Vector3.new(0.4, 1.4, 1.6), base * CFrame.new(-2.3, 0.7, 0), props)
	PartKit.MakePart(parent, "BenchLegE", Vector3.new(0.4, 1.4, 1.6), base * CFrame.new(2.3, 0.7, 0), props)
end

--------------------------------------------------------------------------------
-- PlazaBuilder
--------------------------------------------------------------------------------

local PlazaBuilder = {}

export type PlazaBuild = {
	unboxStage: Model,
	tradePads: { BasePart },
	swapBeaconHead: BasePart, -- tagged "SwapMeetBeacon"; TradeService stamps TradeActive
}

function PlazaBuilder.Build(parent: Model, origin: Vector3): PlazaBuild
	local function at(x: number, y: number, z: number): Vector3
		return origin + Vector3.new(x, y, z)
	end

	local unboxStage = buildUnboxStage(parent, at)
	local tradePads, swapBeaconHead = buildSwapMeet(parent, at)

	-- Bench clusters at the plaza edges (SOP §9): semi-irregular placement,
	-- every bench facing the plaza interior, none inside the queue-pad
	-- approach lane along the plaza center line.
	local benches = Instance.new("Model")
	benches.Name = "PlazaBenches"
	buildBench(benches, at(PLAZA_WEST_X + 7, 0, -46), 180) -- SW edge, faces north
	buildBench(benches, at(PLAZA_WEST_X + 9, 0, 46), 0) -- NW edge, faces south
	buildBench(benches, at(PLAZA_WEST_X + 87, 0, 42), 90) -- NE corner, faces west
	benches.Parent = parent

	return {
		unboxStage = unboxStage,
		tradePads = tradePads,
		swapBeaconHead = swapBeaconHead,
	}
end

return PlazaBuilder
