--!strict
-- CRYPTLINGS: NIGHT SHIFT — QueuePadBuilder: the clock-in queue pad on the
-- Factory plaza (LOBBY_SOP §6.1; build plan WP2.4).
--
-- Pure construction, invoked only by the HubService orchestrator:
-- no signals, no connections, no player logic, no Init/Start. All behavior
-- (membership polling, ring state tinting, countdown text, board renders)
-- lives in QueuePadService / QueuePadUI / SessionStatsService, which receive
-- every live piece through the Build return table.
--
-- Layout convention (shared by every LobbyBuild builder): street axis = X with
-- the Factory at the EAST end; the 10-lot strip
-- (LOTS_PER_SIDE * LOT_FRONTAGE + 9 * LOT_GAP = 522 studs) is centered on
-- `origin`, so the Factory plaza mouth sits at +261 and the Factory facade
-- plane at +261 + FACTORY_PLAZA_DEPTH = +361 (inside ShiftService's 400-stud
-- on-shift heuristic, matching the old hub's centered orientation).
--
-- Built here:
--   * dark 14x14 pad, 1-stud Neon ring border (returned for state tinting),
--     yellow hazard-stripe border, Neon conveyor-stripe path from the street
--     mouth to the pad;
--   * ~60-stud Neon beacon pillar (Transparency 0.7) — QueuePadService dims
--     it while a shift is active;
--   * invisible zone volume 14x6x14 over the pad (CanCollide false,
--     CanQuery true) — THE membership volume (GetPartBoundsInBox, never
--     Touched) and HubService.GetClockInZone's return;
--   * "CLOCK IN HERE" billboard 10 studs up (AlwaysOnTop, MaxDistance 250):
--     line 1 header + bouncing arrow part, line 2 countdown, line 3
--     "0/4 WORKERS", line 4 the empty floors-running anchor (the metronome
--     pad service owns the "CLOCKED IN: n" / "N FLOORS RUNNING" text);
--   * downward SpotLight pillar (46 / 3 / 22) onto the pad;
--   * punch-clock prop at the pad edge (QueuePadService plays the ka-chunk);
--   * "Best Employees" SurfaceGui board on the factory wall behind the pad
--     (Addendum 1 Change 2): "BEST EMPLOYEES" title over 4 portrait cards
--     (rank badge, headshot ImageLabel, name, stat), built EMPTY ("POSITION
--     OPEN" / dark silhouette well / "—") — SessionStatsService owns every
--     render through HubService.GetBestEmployeesBoard(). Neon trim frame
--     only; zero Light instances.
--
-- Facade fixture footprint (so FactoryBuilder/WallBuilder stay clear): the
-- Best Employees board occupies z in [10, 26], y <= 7 on the facade front
-- plane (the retired roster-board slot); the Brainrot wall slab (WallBuilder)
-- sits above it at y >= 7.5.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local LobbyConfig = require(Shared:WaitForChild("Config"):WaitForChild("LobbyConfig"))

local PartKit = require(script.Parent:WaitForChild("PartKit"))

--------------------------------------------------------------------------------
-- Layout constants (derived from LobbyConfig — shared builder convention)
--------------------------------------------------------------------------------

local LOT_STRIP_LENGTH = LobbyConfig.LOTS_PER_SIDE * LobbyConfig.LOT_FRONTAGE_STUDS
	+ (LobbyConfig.LOTS_PER_SIDE - 1) * LobbyConfig.LOT_GAP_STUDS
local PLAZA_WEST_X = LOT_STRIP_LENGTH / 2 -- street mouth of the Factory plaza
local FACADE_X = PLAZA_WEST_X + LobbyConfig.FACTORY_PLAZA_DEPTH_STUDS -- Factory front plane

local PAD_CENTER_X = FACADE_X - 26 -- pad sits on the plaza, in front of the Factory
local PAD_SIZE = LobbyConfig.QUEUE_PAD_SIZE_STUDS
local PAD_THICKNESS = 0.45
local RING_WIDTH = LobbyConfig.QUEUE_RING_WIDTH_STUDS
local RING_HEIGHT = 0.55
local HAZARD_BAND_WIDTH = 1.2
local HAZARD_SEGMENTS_PER_SIDE = 8
local STRIPE_SPACING = 5

-- Best Employees board on the facade, in the retired roster-board slot
-- (z 10-26, y <= 7 — clear of the Brainrot wall slab above it). Board
-- width/height are LobbyConfig.BEST_EMPLOYEES numbers of record.
local BOARD_Z = 18
local BOARD_CENTER_Y = 3.8 -- 6-stud board top lands at 6.8, under the y=7 cap
local BOARD_THICKNESS = 0.8
local BOARD_TRIM_THICK = 0.35 -- Neon frame strip profile (zero Light cost)
local BOARD_TRIM_DEPTH = 0.9 -- 0.05 proud of the board face (no coplanar faces)

-- Card geometry inside the cards row (UIListLayout scale units). Four base
-- cards at 0.225 plus the #1 card's TOP_CARD_SCALE (1.15) and 3 paddings of
-- 0.012 total ~0.97 of the row.
local CARD_BASE_WIDTH = 0.225
local CARD_BASE_HEIGHT = 0.85
local CARD_PADDING = 0.012

--------------------------------------------------------------------------------
-- Night greybox palette (thematic, build-local; SOP numbers stay in LobbyConfig)
--------------------------------------------------------------------------------

local COLOR_PAD = Color3.fromRGB(30, 30, 36)
local COLOR_RING_IDLE = Color3.fromRGB(90, 220, 255) -- idle = cyan (SOP §6.1 ring states)
local COLOR_HAZARD_YELLOW = Color3.fromRGB(235, 190, 52)
local COLOR_HAZARD_DARK = Color3.fromRGB(34, 32, 30)
local COLOR_ARROW = Color3.fromRGB(255, 196, 90)
local COLOR_STEEL = Color3.fromRGB(96, 100, 110)
local COLOR_FIXTURE = Color3.fromRGB(44, 44, 52)
local COLOR_BOARD = Color3.fromRGB(24, 22, 28)
local COLOR_CARD = Color3.fromRGB(38, 36, 46)
local COLOR_CARD_WELL = Color3.fromRGB(18, 17, 22) -- empty-portrait silhouette well
local COLOR_OPEN_TEXT = Color3.fromRGB(150, 150, 160)
local COLOR_SPOT_COOL = Color3.fromRGB(210, 225, 255)

-- Rank badge colors #1-#4 (gold / silver / bronze / steel); gold doubles as
-- the board's Neon trim accent (bright enough to clear BLOOM.THRESHOLD 1.1).
local RANK_COLORS: { Color3 } = {
	Color3.fromRGB(255, 200, 80), -- #1 gold
	Color3.fromRGB(205, 210, 220), -- #2 silver
	Color3.fromRGB(205, 130, 70), -- #3 bronze
	COLOR_STEEL, -- #4 steel
}

--------------------------------------------------------------------------------
-- Types
--------------------------------------------------------------------------------

-- One Best Employees portrait card (R2 Wave-2 interface contract). Built in
-- the EMPTY state; SessionStatsService renders rank/name/"N CRATES"/rbxthumb.
export type BestEmployeesCard = {
	card: Frame,
	rankLabel: TextLabel,
	portrait: ImageLabel,
	nameLabel: TextLabel,
	statLabel: TextLabel,
}

export type QueuePadBuild = {
	model: Model,
	pad: BasePart,
	zonePart: BasePart,
	ringParts: { BasePart },
	beacon: BasePart,
	billboard: BillboardGui,
	billboardLabels: { TextLabel }, -- [1] header, [2] countdown, [3] workers, [4] floors
	clockInLabel: TextLabel,
	countdownLabel: TextLabel,
	workersLabel: TextLabel,
	floorsLabel: TextLabel, -- Line4 anchor ("N FLOORS RUNNING" — pad service owns text)
	arrow: BasePart,
	bestEmployeesBoard: BasePart,
	bestEmployeesCards: { BestEmployeesCard },
	punchClock: Model,
}

local QueuePadBuilder = {}

--------------------------------------------------------------------------------
-- Build
--------------------------------------------------------------------------------

function QueuePadBuilder.Build(parent: Model, origin: Vector3): QueuePadBuild
	local model = Instance.new("Model")
	model.Name = "QueuePad"

	local function rel(x: number, y: number, z: number): Vector3
		return origin + Vector3.new(x, y, z)
	end

	local padHalf = PAD_SIZE / 2
	local padTop = PAD_THICKNESS

	-- Pad: dark 14x14 slab the workers stand on.
	local pad = PartKit.MakePart(
		model,
		"QueuePad",
		Vector3.new(PAD_SIZE, PAD_THICKNESS, PAD_SIZE),
		CFrame.new(rel(PAD_CENTER_X, PAD_THICKNESS / 2, 0)),
		{ color = COLOR_PAD }
	)

	-- 1-stud Neon ring border (idle cyan; QueuePadService re-tints per state).
	local ringParts: { BasePart } = {}
	local ringOuter = PAD_SIZE + RING_WIDTH * 2
	local ringProps: PartKit.PartProps = { color = COLOR_RING_IDLE, material = Enum.Material.Neon, transparency = 0.55 }
	for _, zSign in { -1, 1 } do
		table.insert(
			ringParts,
			PartKit.MakePart(
				model,
				"QueueRing",
				Vector3.new(ringOuter, RING_HEIGHT, RING_WIDTH),
				CFrame.new(rel(PAD_CENTER_X, RING_HEIGHT / 2, zSign * (padHalf + RING_WIDTH / 2))),
				ringProps
			)
		)
	end
	for _, xSign in { -1, 1 } do
		table.insert(
			ringParts,
			PartKit.MakePart(
				model,
				"QueueRing",
				Vector3.new(RING_WIDTH, RING_HEIGHT, PAD_SIZE),
				CFrame.new(rel(PAD_CENTER_X + xSign * (padHalf + RING_WIDTH / 2), RING_HEIGHT / 2, 0)),
				ringProps
			)
		)
	end

	-- Yellow hazard-stripe border just outside the ring (factory-coded).
	local hazardInner = padHalf + RING_WIDTH
	local hazardCenterOffset = hazardInner + HAZARD_BAND_WIDTH / 2
	local hazardOuterLength = (hazardInner + HAZARD_BAND_WIDTH) * 2
	local segmentLengthX = hazardOuterLength / HAZARD_SEGMENTS_PER_SIDE
	for index = 0, HAZARD_SEGMENTS_PER_SIDE - 1 do
		local x = -hazardOuterLength / 2 + segmentLengthX * (index + 0.5)
		for sideIndex, zSign in { -1, 1 } do
			local color = if (index + sideIndex) % 2 == 0 then COLOR_HAZARD_YELLOW else COLOR_HAZARD_DARK
			PartKit.MakePart(
				model,
				"HazardSegment",
				Vector3.new(segmentLengthX, 0.3, HAZARD_BAND_WIDTH),
				CFrame.new(rel(PAD_CENTER_X + x, 0.15, zSign * hazardCenterOffset)),
				{ color = color, decor = true }
			)
		end
	end
	local sideLengthZ = hazardInner * 2
	local segmentLengthZ = sideLengthZ / HAZARD_SEGMENTS_PER_SIDE
	for index = 0, HAZARD_SEGMENTS_PER_SIDE - 1 do
		local z = -sideLengthZ / 2 + segmentLengthZ * (index + 0.5)
		for sideIndex, xSign in { -1, 1 } do
			local color = if (index + sideIndex) % 2 == 0 then COLOR_HAZARD_YELLOW else COLOR_HAZARD_DARK
			PartKit.MakePart(
				model,
				"HazardSegment",
				Vector3.new(HAZARD_BAND_WIDTH, 0.3, segmentLengthZ),
				CFrame.new(rel(PAD_CENTER_X + xSign * hazardCenterOffset, 0.15, z)),
				{ color = color, decor = true }
			)
		end
	end

	-- Neon conveyor-stripe path from the street mouth to the pad edge.
	local stripeStartX = PLAZA_WEST_X + 2
	local stripeEndX = PAD_CENTER_X - (hazardInner + HAZARD_BAND_WIDTH + 1.3)
	local stripeX = stripeStartX
	while stripeX <= stripeEndX do
		PartKit.MakePart(
			model,
			"ConveyorStripe",
			Vector3.new(1.2, 0.12, 4),
			CFrame.new(rel(stripeX, 0.06, 0)),
			{ color = COLOR_RING_IDLE, material = Enum.Material.Neon, transparency = 0.4, decor = true }
		)
		stripeX += STRIPE_SPACING
	end

	-- Vertical beacon: thin Neon pillar visible from the Coming Soon end;
	-- QueuePadService dims it while a shift is active.
	local beacon = PartKit.MakeUprightCylinder(
		model,
		"QueueBeacon",
		LobbyConfig.QUEUE_BEACON_HEIGHT_STUDS,
		1.6,
		rel(PAD_CENTER_X, padTop + LobbyConfig.QUEUE_BEACON_HEIGHT_STUDS / 2, 0),
		{
			color = COLOR_RING_IDLE,
			material = Enum.Material.Neon,
			transparency = LobbyConfig.QUEUE_BEACON_TRANSPARENCY,
			decor = true,
		}
	)

	-- Invisible membership zone volume over the pad (zone, never Touched):
	-- CanCollide false, CanQuery true — QueuePadService polls it with
	-- GetPartBoundsInBox; HubService.GetClockInZone returns it.
	local zone = PartKit.MakePart(
		model,
		"ClockInZone",
		Vector3.new(PAD_SIZE, LobbyConfig.QUEUE_ZONE_HEIGHT_STUDS, PAD_SIZE),
		CFrame.new(rel(PAD_CENTER_X, padTop + LobbyConfig.QUEUE_ZONE_HEIGHT_STUDS / 2, 0)),
		{ transparency = 1, decor = true, canQuery = true }
	)

	-- "clock in here" billboard 10 studs up (SOP §6.1 verbatim header casing).
	local billboardAnchor = PartKit.MakePart(
		model,
		"ClockInBillboardAnchor",
		Vector3.one,
		CFrame.new(rel(PAD_CENTER_X, padTop + LobbyConfig.QUEUE_BILLBOARD_HEIGHT_STUDS, 0)),
		{ transparency = 1, decor = true }
	)
	-- Line 4 is the empty floors-running anchor (Addendum 1 Change 6): the
	-- metronome pad service owns the "CLOCKED IN: n" / "N FLOORS RUNNING" text.
	local countdownText = string.format("%d:%02d", LobbyConfig.QUEUE_SECONDS // 60, LobbyConfig.QUEUE_SECONDS % 60)
	local billboard, billboardLabels = PartKit.MakeBillboard(
		billboardAnchor,
		LobbyConfig.BILLBOARD_MAX_DISTANCE.CLOCK_IN,
		{ "CLOCK IN HERE", countdownText, `0/{LobbyConfig.QUEUE_CAPACITY} WORKERS`, "" },
		{ alwaysOnTop = true, name = "ClockInBillboard" }
	)

	-- Downward arrow part under the billboard (QueuePadUI bounce-tweens it
	-- ±QUEUE_ARROW_BOUNCE_STUDS on a Sine loop).
	local arrow = PartKit.MakePart(
		model,
		"ClockInArrow",
		Vector3.new(1.7, 1.7, 0.7),
		CFrame.new(rel(PAD_CENTER_X, padTop + 7.4, 0)) * CFrame.Angles(0, 0, math.rad(45)),
		{ color = COLOR_ARROW, material = Enum.Material.Neon, decor = true }
	)

	-- Downward SpotLight pillar onto the pad (46 / 3 / 22), mounted as a
	-- collar fixture on the beacon so it never floats unsupported.
	local spotFixture = PartKit.MakePart(
		model,
		"PadSpotFixture",
		Vector3.new(2, 0.6, 2),
		CFrame.new(rel(PAD_CENTER_X, 20, 0)),
		{ color = COLOR_FIXTURE, decor = true }
	)
	PartKit.MakeSpot(spotFixture, {
		angle = LobbyConfig.QUEUE_PAD_SPOT.ANGLE,
		range = LobbyConfig.QUEUE_PAD_SPOT.RANGE,
		brightness = LobbyConfig.QUEUE_PAD_SPOT.BRIGHTNESS,
		color = COLOR_SPOT_COOL,
	})

	-- Punch-clock prop at the pad edge ("ka-chunk" SFX lives in QueuePadService).
	local punchClock = Instance.new("Model")
	punchClock.Name = "PunchClock"
	local post = PartKit.MakePart(
		punchClock,
		"Post",
		Vector3.new(0.6, 3.4, 0.6),
		CFrame.new(rel(PAD_CENTER_X - 9.4, 1.7, 9.4)),
		{ color = COLOR_STEEL }
	)
	PartKit.MakePart(
		punchClock,
		"Head",
		Vector3.new(1.8, 1.4, 1),
		CFrame.new(rel(PAD_CENTER_X - 9.4, 3.8, 9.4)),
		{ color = COLOR_STEEL }
	)
	PartKit.MakePart(
		punchClock,
		"Slot",
		Vector3.new(1.2, 0.18, 0.2),
		CFrame.new(rel(PAD_CENTER_X - 9.4, 3.8, 8.85)),
		{ color = COLOR_HAZARD_YELLOW, material = Enum.Material.Neon, decor = true }
	)
	punchClock.PrimaryPart = post
	punchClock.Parent = model

	-- Best Employees board on the factory wall behind the pad (Addendum 1
	-- Change 2): "BEST EMPLOYEES" title over 4 portrait cards, #1 card 15%
	-- larger, gold Neon trim frame (zero Light). Cards build EMPTY ("POSITION
	-- OPEN" / dark silhouette well / "—"); SessionStatsService owns every
	-- render. West face sits 0.05 studs proud of the facade plane (no
	-- z-fighting).
	local boardWidth = LobbyConfig.BEST_EMPLOYEES.BOARD_WIDTH
	local boardHeight = LobbyConfig.BEST_EMPLOYEES.BOARD_HEIGHT
	local boardCFrame = CFrame.new(rel(FACADE_X - 0.45, BOARD_CENTER_Y, BOARD_Z)) * CFrame.Angles(0, math.rad(90), 0)
	local board = PartKit.MakePart(
		model,
		"BestEmployeesBoard",
		Vector3.new(boardWidth, boardHeight, BOARD_THICKNESS),
		boardCFrame,
		{ color = COLOR_BOARD }
	)

	-- Neon trim frame around the board perimeter (Change 2 glow path — Neon
	-- only, never a Light instance). Strips are 0.05 proud of the board face.
	local trimProps: PartKit.PartProps = { color = RANK_COLORS[1], material = Enum.Material.Neon, decor = true }
	for _, ySign in { -1, 1 } do
		PartKit.MakePart(
			model,
			"BoardTrim",
			Vector3.new(boardWidth + BOARD_TRIM_THICK * 2, BOARD_TRIM_THICK, BOARD_TRIM_DEPTH),
			boardCFrame * CFrame.new(0, ySign * (boardHeight + BOARD_TRIM_THICK) / 2, 0),
			trimProps
		)
	end
	for _, xSign in { -1, 1 } do
		PartKit.MakePart(
			model,
			"BoardTrim",
			Vector3.new(BOARD_TRIM_THICK, boardHeight, BOARD_TRIM_DEPTH),
			boardCFrame * CFrame.new(xSign * (boardWidth + BOARD_TRIM_THICK) / 2, 0, 0),
			trimProps
		)
	end

	local boardGui = PartKit.MakeSurfaceGui(board, "BestEmployeesGui")
	PartKit.MakeLabel(boardGui, "Title", "BEST EMPLOYEES", UDim2.fromScale(0, 0), UDim2.fromScale(1, 0.16))

	local cardsRow = Instance.new("Frame")
	cardsRow.Name = "Cards"
	cardsRow.BackgroundTransparency = 1
	cardsRow.Position = UDim2.fromScale(0.02, 0.17)
	cardsRow.Size = UDim2.fromScale(0.96, 0.81)
	cardsRow.Parent = boardGui

	local cardsLayout = Instance.new("UIListLayout")
	cardsLayout.FillDirection = Enum.FillDirection.Horizontal
	cardsLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	cardsLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	cardsLayout.SortOrder = Enum.SortOrder.LayoutOrder
	cardsLayout.Padding = UDim.new(CARD_PADDING, 0)
	cardsLayout.Parent = cardsRow

	local bestEmployeesCards: { BestEmployeesCard } = {}
	for index = 1, LobbyConfig.BEST_EMPLOYEES.CARD_COUNT do
		local scale = if index == 1 then LobbyConfig.BEST_EMPLOYEES.TOP_CARD_SCALE else 1
		local card = Instance.new("Frame")
		card.Name = `Card{index}`
		card.LayoutOrder = index
		card.BackgroundColor3 = COLOR_CARD
		card.BackgroundTransparency = 0.1
		card.BorderSizePixel = 0
		card.Size = UDim2.fromScale(CARD_BASE_WIDTH * scale, CARD_BASE_HEIGHT * scale)
		card.Parent = cardsRow

		local rankLabel = PartKit.MakeLabel(
			card,
			"RankLabel",
			`#{index}`,
			UDim2.fromScale(0.05, 0.02),
			UDim2.fromScale(0.9, 0.14),
			RANK_COLORS[index]
		)

		local portrait = Instance.new("ImageLabel")
		portrait.Name = "Portrait"
		portrait.BackgroundColor3 = COLOR_CARD_WELL
		portrait.BackgroundTransparency = 0.15
		portrait.BorderSizePixel = 0
		portrait.Image = "" -- empty silhouette well until a headshot renders
		portrait.Position = UDim2.fromScale(0.16, 0.18)
		portrait.Size = UDim2.fromScale(0.68, 0.5)
		portrait.Parent = card

		local nameLabel = PartKit.MakeLabel(
			card,
			"NameLabel",
			"POSITION OPEN",
			UDim2.fromScale(0.05, 0.7),
			UDim2.fromScale(0.9, 0.16),
			COLOR_OPEN_TEXT
		)
		local statLabel = PartKit.MakeLabel(
			card,
			"StatLabel",
			"—",
			UDim2.fromScale(0.05, 0.86),
			UDim2.fromScale(0.9, 0.12),
			COLOR_OPEN_TEXT
		)

		table.insert(bestEmployeesCards, {
			card = card,
			rankLabel = rankLabel,
			portrait = portrait,
			nameLabel = nameLabel,
			statLabel = statLabel,
		})
	end

	model.Parent = parent

	return {
		model = model,
		pad = pad,
		zonePart = zone,
		ringParts = ringParts,
		beacon = beacon,
		billboard = billboard,
		billboardLabels = billboardLabels,
		clockInLabel = billboardLabels[1],
		countdownLabel = billboardLabels[2],
		workersLabel = billboardLabels[3],
		floorsLabel = billboardLabels[4],
		arrow = arrow,
		bestEmployeesBoard = board,
		bestEmployeesCards = bestEmployeesCards,
		punchClock = punchClock,
	}
end

return QueuePadBuilder
