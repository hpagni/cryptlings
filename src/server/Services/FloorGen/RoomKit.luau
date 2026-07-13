--!strict
-- CRYPTLINGS: NIGHT SHIFT — RoomKit: greybox room-variant recipes (Stage 1, floor-procgen).
-- Builds one CELL_SIZE x CELL_SIZE room per call purely from anchored Parts —
-- no meshes, no art assets (SOP greybox rule). Wall ownership and doorway
-- openness are decided by FloorGenService (each cell owns its N/E walls plus
-- the S/W walls when it sits on the grid boundary) so every shared wall is
-- built exactly once. RoomKit only creates Parts and reports semantic
-- positions (case-anchor candidates, light socket, vault pedestal, dock pads
-- and extraction volume); ALL CollectionService tagging stays in
-- FloorGenService so tag semantics live in one file.
--
-- Variants: ConveyorHall · ShelvingMaze · VatRoom · Office · Vault · Dock.
-- Doorways are centered on each side, so interiors keep the two centered
-- corridors (the x = 0 and z = 0 lines near the doors) clear enough that no
-- doorway can ever be sealed off by furniture.
--
-- Determinism: every rng decision comes from params.rng (a child Random
-- forked per room by FloorGenService) — same seed, same room.

local RoomKit = {}

--------------------------------------------------------------------------------
-- Greybox geometry constants (pure level-art dimensions; gameplay tunables
-- live in Config/GameConstants per contract G — nothing here is referenced by
-- any other system).
--------------------------------------------------------------------------------

local WALL_THICKNESS = 1
local DOOR_WIDTH = 10
local DOOR_HEIGHT = 12
local FLOOR_THICKNESS = 1
local SHUTTER_WIDTH = 14
local SHUTTER_HEIGHT = 12

local COLOR_WALL = Color3.fromRGB(106, 104, 110)
local COLOR_FLOOR_DEFAULT = Color3.fromRGB(76, 76, 80)
local COLOR_CONVEYOR = Color3.fromRGB(52, 52, 58)
local COLOR_SHELF = Color3.fromRGB(94, 94, 100)
local COLOR_VAT = Color3.fromRGB(70, 92, 86)
local COLOR_PIPE = Color3.fromRGB(88, 84, 78)
local COLOR_DESK = Color3.fromRGB(104, 92, 76)
local COLOR_CRATE = Color3.fromRGB(112, 98, 70)
local COLOR_PILLAR = Color3.fromRGB(58, 56, 62)
local COLOR_PEDESTAL = Color3.fromRGB(96, 88, 56)
local COLOR_SHUTTER = Color3.fromRGB(140, 118, 64)
local COLOR_VAULT_DOOR = Color3.fromRGB(168, 138, 52)
local COLOR_EXTRACT_GLOW = Color3.fromRGB(90, 255, 150) -- neon green exit glow; blooms (max channel >= 217)
local COLOR_PAD = Color3.fromRGB(120, 132, 150)

local FLOOR_COLORS: { [string]: Color3 } = {
	ConveyorHall = Color3.fromRGB(78, 78, 84),
	ShelvingMaze = Color3.fromRGB(74, 78, 74),
	VatRoom = Color3.fromRGB(70, 76, 80),
	Office = Color3.fromRGB(82, 78, 74),
	Vault = Color3.fromRGB(84, 78, 58),
	Dock = Color3.fromRGB(66, 70, 78),
}

local SIDE_DIRECTIONS: { [string]: Vector3 } = {
	N = Vector3.new(0, 0, 1),
	S = Vector3.new(0, 0, -1),
	E = Vector3.new(1, 0, 0),
	W = Vector3.new(-1, 0, 0),
}

-- The random pool FloorGenService draws regular rooms from (Dock/Vault are
-- placed explicitly, never rolled).
RoomKit.GENERIC_VARIANTS = { "ConveyorHall", "ShelvingMaze", "VatRoom", "Office" } :: { string }

--------------------------------------------------------------------------------
-- Types
--------------------------------------------------------------------------------

export type SideSpec = { owned: boolean, open: boolean }
export type Sides = { [string]: SideSpec } -- keys "N" | "E" | "S" | "W"

export type RoomParams = {
	variant: string,
	center: Vector3, -- world-space cell center on the floor-top plane (y = 0)
	cellSize: number,
	wallHeight: number,
	rng: Random,
	sides: Sides,
	outerSide: string?, -- Dock only: boundary side that receives the shutter assembly
}

export type RoomResult = {
	parts: { BasePart },
	caseAnchorPositions: { Vector3 }, -- candidates; FloorGenService picks + tags
	lightPosition: Vector3,
	vaultAnchorPosition: Vector3?, -- Vault only: pedestal top
	dockSpawns: { BasePart }, -- Dock only
	extractZone: BasePart?, -- Dock only: the "ExtractDock" trigger volume
}

type PartSpec = {
	name: string?,
	size: Vector3,
	cframe: CFrame,
	color: Color3?,
	material: Enum.Material?,
	transparency: number?,
	canCollide: boolean?,
	canTouch: boolean?,
	canQuery: boolean?,
	shape: Enum.PartType?,
}

--------------------------------------------------------------------------------
-- Part factory
--------------------------------------------------------------------------------

local function makePart(parent: Instance, result: RoomResult, spec: PartSpec): Part
	local part = Instance.new("Part")
	part.Name = spec.name or "Greybox"
	part.Anchored = true
	part.Size = spec.size
	part.CFrame = spec.cframe
	part.Color = spec.color or COLOR_WALL
	part.Material = spec.material or Enum.Material.SmoothPlastic
	part.Transparency = spec.transparency or 0
	part.CanCollide = spec.canCollide ~= false
	part.CanTouch = spec.canTouch ~= false
	part.CanQuery = spec.canQuery ~= false
	if spec.shape ~= nil then
		part.Shape = spec.shape
	end
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	table.insert(result.parts, part)
	return part
end

-- Upright cylinder helper (Roblox cylinders lie along their X axis).
local function uprightCylinderCFrame(position: Vector3): CFrame
	return CFrame.new(position) * CFrame.Angles(0, 0, math.rad(90))
end

--------------------------------------------------------------------------------
-- Walls
--------------------------------------------------------------------------------

-- Builds one wall on `side` of the cell. gapWidth == nil -> solid wall (1 part);
-- otherwise two jambs + a lintel leave a centered doorway gap (3 parts).
local function buildWall(
	parent: Instance,
	params: RoomParams,
	result: RoomResult,
	side: string,
	gapWidth: number?,
	gapHeight: number?
)
	local dir = SIDE_DIRECTIONS[side]
	local alongX = side == "N" or side == "S"
	local half = params.cellSize / 2
	local height = params.wallHeight
	local runLength = params.cellSize + WALL_THICKNESS -- overrun seals corners
	local edgeCenter = params.center + dir * half

	local function piece(name: string, runOffset: number, runLen: number, yBottom: number, pieceHeight: number)
		local offset = if alongX then Vector3.new(runOffset, 0, 0) else Vector3.new(0, 0, runOffset)
		local size = if alongX
			then Vector3.new(runLen, pieceHeight, WALL_THICKNESS)
			else Vector3.new(WALL_THICKNESS, pieceHeight, runLen)
		makePart(parent, result, {
			name = name,
			size = size,
			cframe = CFrame.new(edgeCenter + offset + Vector3.new(0, yBottom + pieceHeight / 2, 0)),
			color = COLOR_WALL,
			material = Enum.Material.Concrete,
		})
	end

	if gapWidth == nil then
		piece("Wall", 0, runLength, 0, height)
	else
		local gw = gapWidth
		local gh = gapHeight or DOOR_HEIGHT
		local jambLen = (runLength - gw) / 2
		piece("WallJamb", (gw + jambLen) / 2, jambLen, 0, height)
		piece("WallJamb", -(gw + jambLen) / 2, jambLen, 0, height)
		if height > gh then
			piece("WallLintel", 0, gw, gh, height - gh)
		end
	end
end

-- A locked-door fill sized to the standard doorway gap; FloorGenService places
-- one on the vault's single entrance and tags it "VaultDoor" (opened by the
-- Foreman's Key in Stage 6).
function RoomKit.BuildDoorFill(parent: Instance, edgeCenter: Vector3, alongX: boolean, name: string?): Part
	local result: RoomResult = { parts = {}, caseAnchorPositions = {}, lightPosition = edgeCenter, dockSpawns = {} }
	return makePart(parent, result, {
		name = name or "DoorFill",
		size = if alongX
			then Vector3.new(DOOR_WIDTH, DOOR_HEIGHT, WALL_THICKNESS + 0.4)
			else Vector3.new(WALL_THICKNESS + 0.4, DOOR_HEIGHT, DOOR_WIDTH),
		cframe = CFrame.new(edgeCenter + Vector3.new(0, DOOR_HEIGHT / 2, 0)),
		color = COLOR_VAULT_DOOR,
		material = Enum.Material.Metal,
	})
end

--------------------------------------------------------------------------------
-- Shared dressing
--------------------------------------------------------------------------------

local function addCrate(parent: Instance, result: RoomResult, position: Vector3, rng: Random)
	local side = 2.6 + rng:NextNumber() * 1
	makePart(parent, result, {
		name = "Crate",
		size = Vector3.new(side, side, side),
		cframe = CFrame.new(position + Vector3.new(0, side / 2, 0)) * CFrame.Angles(0, rng:NextNumber() * math.pi, 0),
		color = COLOR_CRATE,
		material = Enum.Material.WoodPlanks,
	})
end

--------------------------------------------------------------------------------
-- Variant interiors (q = cellSize / 4 = quadrant centers; corridors at x = 0
-- and z = 0 stay clear of large furniture so doors are never sealed)
--------------------------------------------------------------------------------

local function buildConveyorHall(parent: Instance, params: RoomParams, result: RoomResult)
	local c = params.center
	local q = params.cellSize / 4
	for _, zSign in { -1, 1 } do
		local beltZ = q * zSign
		makePart(parent, result, {
			name = "Conveyor",
			size = Vector3.new(params.cellSize - 10, 2.4, 4),
			cframe = CFrame.new(c + Vector3.new(0, 1.2, beltZ)),
			color = COLOR_CONVEYOR,
			material = Enum.Material.DiamondPlate,
		})
		for _, xSign in { -1, 1 } do
			table.insert(result.caseAnchorPositions, c + Vector3.new((params.cellSize / 2 - 9) * xSign, 3.4, beltZ))
		end
	end
	local crateSign = params.rng:NextInteger(0, 1) * 2 - 1
	addCrate(parent, result, c + Vector3.new(q * crateSign, 0, params.rng:NextNumber(-3, 3)), params.rng)
end

local function buildShelvingMaze(parent: Instance, params: RoomParams, result: RoomResult)
	local c = params.center
	local q = params.cellSize / 4
	local centerShelfSign = params.rng:NextInteger(0, 1) * 2 - 1
	local shelfSpots = {
		Vector3.new(-8, 0, -q),
		Vector3.new(8, 0, -q),
		Vector3.new(-8, 0, q),
		Vector3.new(8, 0, q),
		Vector3.new(8 * centerShelfSign, 0, 0),
	}
	for _, spot in shelfSpots do
		local jitter = Vector3.new(params.rng:NextNumber(-1.5, 1.5), 0, 0)
		makePart(parent, result, {
			name = "Shelf",
			size = Vector3.new(10, 9, 2),
			cframe = CFrame.new(c + spot + jitter + Vector3.new(0, 4.5, 0)),
			color = COLOR_SHELF,
			material = Enum.Material.Metal,
		})
	end
	table.insert(result.caseAnchorPositions, c + Vector3.new(0, 1.2, -q))
	table.insert(result.caseAnchorPositions, c + Vector3.new(0, 1.2, q))
	table.insert(result.caseAnchorPositions, c + Vector3.new(-centerShelfSign * (q + 2), 1.2, 0))
end

local function buildVatRoom(parent: Instance, params: RoomParams, result: RoomResult)
	local c = params.center
	local q = params.cellSize / 4
	local vatSpots = { Vector3.new(-q, 0, -q), Vector3.new(q, 0, -q), Vector3.new(-q, 0, q) }
	for _, spot in vatSpots do
		local jitter = Vector3.new(params.rng:NextNumber(-1, 1), 0, params.rng:NextNumber(-1, 1))
		makePart(parent, result, {
			name = "Vat",
			size = Vector3.new(7, 7, 7),
			cframe = uprightCylinderCFrame(c + spot + jitter + Vector3.new(0, 3.5, 0)),
			color = COLOR_VAT,
			material = Enum.Material.Metal,
			shape = Enum.PartType.Cylinder,
		})
	end
	makePart(parent, result, {
		name = "Pipe",
		size = Vector3.new(params.cellSize - 6, 1.5, 1.5),
		cframe = CFrame.new(c + Vector3.new(0, params.wallHeight - 4, q)),
		color = COLOR_PIPE,
		material = Enum.Material.Metal,
		shape = Enum.PartType.Cylinder,
		canCollide = false,
	})
	table.insert(result.caseAnchorPositions, c + Vector3.new(q, 1.2, q))
	table.insert(result.caseAnchorPositions, c + Vector3.new(-q + 6, 1.2, -q))
	table.insert(result.caseAnchorPositions, c + Vector3.new(-q, 1.2, q - 6))
end

local function buildOffice(parent: Instance, params: RoomParams, result: RoomResult)
	local c = params.center
	local q = params.cellSize / 4
	for _, sign in { -1, 1 } do
		local deskAt = c + Vector3.new(q * sign, 0, q * sign)
		makePart(parent, result, {
			name = "DeskBase",
			size = Vector3.new(5, 1.8, 2.5),
			cframe = CFrame.new(deskAt + Vector3.new(0, 0.9, 0)),
			color = COLOR_DESK,
			material = Enum.Material.Wood,
		})
		makePart(parent, result, {
			name = "DeskTop",
			size = Vector3.new(7, 0.8, 3.5),
			cframe = CFrame.new(deskAt + Vector3.new(0, 2.2, 0)),
			color = COLOR_DESK,
			material = Enum.Material.Wood,
		})
		table.insert(result.caseAnchorPositions, deskAt + Vector3.new(0, 3.4, 0))
	end
	makePart(parent, result, {
		name = "Cabinet",
		size = Vector3.new(3, 7, 2),
		cframe = CFrame.new(c + Vector3.new(q, 3.5, -q)),
		color = COLOR_SHELF,
		material = Enum.Material.Metal,
	})
	makePart(parent, result, {
		name = "Partition",
		size = Vector3.new(8, 6, 0.8),
		cframe = CFrame.new(c + Vector3.new(-q, 3, q)),
		color = COLOR_WALL,
		material = Enum.Material.Plastic,
	})
	table.insert(result.caseAnchorPositions, c + Vector3.new(q, 1.2, -q + 5))
end

local function buildVault(parent: Instance, params: RoomParams, result: RoomResult)
	local c = params.center
	local q = params.cellSize / 4
	for _, xSign in { -1, 1 } do
		for _, zSign in { -1, 1 } do
			makePart(parent, result, {
				name = "VaultPillar",
				size = Vector3.new(2, 12, 2),
				cframe = CFrame.new(c + Vector3.new((q + 1) * xSign, 6, (q + 1) * zSign)),
				color = COLOR_PILLAR,
				material = Enum.Material.Concrete,
			})
		end
	end
	makePart(parent, result, {
		name = "VaultPedestal",
		size = Vector3.new(3, 2.6, 3),
		cframe = CFrame.new(c + Vector3.new(0, 1.3, 0)),
		color = COLOR_PEDESTAL,
		material = Enum.Material.Metal,
	})
	-- Single Tier3 anchor on the pedestal; FloorGenService tags it
	-- "VaultCaseSpawn" (NOT "CaseSpawn" — Foreman's Key flow only, Stage 6).
	result.vaultAnchorPosition = c + Vector3.new(0, 3.8, 0)
end

local function buildDock(parent: Instance, params: RoomParams, result: RoomResult)
	local c = params.center
	local q = params.cellSize / 4
	local outer = params.outerSide or "S"
	local outDir = SIDE_DIRECTIONS[outer]
	local inDir = -outDir
	local alongX = outer == "N" or outer == "S"
	local perp = if alongX then Vector3.new(1, 0, 0) else Vector3.new(0, 0, 1)

	-- Big shutter door set into the outer boundary wall (jambs + lintel + the
	-- closed shutter itself).
	buildWall(parent, params, result, outer, SHUTTER_WIDTH, SHUTTER_HEIGHT)
	local edgeCenter = c + outDir * (params.cellSize / 2)
	makePart(parent, result, {
		name = "ShutterDoor",
		size = if alongX
			then Vector3.new(SHUTTER_WIDTH - 0.4, SHUTTER_HEIGHT - 0.4, 1.4)
			else Vector3.new(1.4, SHUTTER_HEIGHT - 0.4, SHUTTER_WIDTH - 0.4),
		cframe = CFrame.new(edgeCenter + Vector3.new(0, (SHUTTER_HEIGHT - 0.4) / 2, 0)),
		color = COLOR_SHUTTER,
		material = Enum.Material.CorrodedMetal,
	})

	-- Extraction trigger volume just inside the shutter (banking happens here).
	-- Glows green so the way OUT reads from across the dark floor. (Touch/query
	-- left at the defaults so extraction detection is unaffected.)
	result.extractZone = makePart(parent, result, {
		name = "ExtractDock",
		size = if alongX then Vector3.new(params.cellSize - 8, 10, 8) else Vector3.new(8, 10, params.cellSize - 8),
		cframe = CFrame.new(c + outDir * (params.cellSize / 2 - 5) + Vector3.new(0, 5, 0)),
		color = COLOR_EXTRACT_GLOW,
		material = Enum.Material.Neon,
		transparency = 0.55,
		canCollide = false,
	})

	-- Glowing EXIT frame around the shutter: two neon posts + a lintel beam, plus
	-- a green light that actually illuminates the dock mouth — the floor exit is
	-- the one thing a lost player should always be able to find in the dark.
	local postOffset = SHUTTER_WIDTH / 2 + 0.6
	for _, sign in { -1, 1 } do
		makePart(parent, result, {
			name = "ExitGlowPost",
			size = Vector3.new(1, SHUTTER_HEIGHT, 1),
			cframe = CFrame.new(edgeCenter + perp * (sign * postOffset) + Vector3.new(0, SHUTTER_HEIGHT / 2, 0)),
			color = COLOR_EXTRACT_GLOW,
			material = Enum.Material.Neon,
			canCollide = false,
			canTouch = false,
			canQuery = false,
		})
	end
	local lintel = makePart(parent, result, {
		name = "ExitGlowLintel",
		size = if alongX then Vector3.new(SHUTTER_WIDTH + 2, 1, 1) else Vector3.new(1, 1, SHUTTER_WIDTH + 2),
		cframe = CFrame.new(edgeCenter + Vector3.new(0, SHUTTER_HEIGHT + 0.5, 0)),
		color = COLOR_EXTRACT_GLOW,
		material = Enum.Material.Neon,
		canCollide = false,
		canTouch = false,
		canQuery = false,
	})
	local exitLight = Instance.new("PointLight")
	exitLight.Color = COLOR_EXTRACT_GLOW
	exitLight.Brightness = 3
	exitLight.Range = 32
	exitLight.Shadows = false -- mobile perf (SOP §3.2)
	exitLight.Parent = lintel

	-- Four spawn pads on the inner half of the dock.
	for i = 1, 4 do
		local lateral = (i - 2.5) * 7 -- -10.5, -3.5, 3.5, 10.5
		local pad = makePart(parent, result, {
			name = "DockSpawn",
			size = Vector3.new(4, 0.5, 4),
			cframe = CFrame.new(c + inDir * q + perp * lateral + Vector3.new(0, 0.25, 0)),
			color = COLOR_PAD,
			material = Enum.Material.SmoothPlastic,
		})
		table.insert(result.dockSpawns, pad)
	end

	-- Dressing crates by the side walls.
	addCrate(parent, result, c + perp * 12, params.rng)
	addCrate(parent, result, c - perp * 12 + inDir * params.rng:NextNumber(0, 3), params.rng)
end

local VARIANT_BUILDERS: { [string]: (Instance, RoomParams, RoomResult) -> () } = {
	ConveyorHall = buildConveyorHall,
	ShelvingMaze = buildShelvingMaze,
	VatRoom = buildVatRoom,
	Office = buildOffice,
	Vault = buildVault,
	Dock = buildDock,
}

--------------------------------------------------------------------------------
-- Public build entry point
--------------------------------------------------------------------------------

function RoomKit.Build(parent: Instance, params: RoomParams): RoomResult
	local result: RoomResult = {
		parts = {},
		caseAnchorPositions = {},
		lightPosition = params.center + Vector3.new(0, params.wallHeight - 1.5, 0),
		dockSpawns = {},
	}

	-- Floor slab (top face at y = 0 of the room plane; slabs tile seamlessly).
	makePart(parent, result, {
		name = "RoomFloor",
		size = Vector3.new(params.cellSize, FLOOR_THICKNESS, params.cellSize),
		cframe = CFrame.new(params.center - Vector3.new(0, FLOOR_THICKNESS / 2, 0)),
		color = FLOOR_COLORS[params.variant] or COLOR_FLOOR_DEFAULT,
		material = Enum.Material.Concrete,
	})

	-- Owned walls (solid or with a centered doorway gap).
	for _, side in { "N", "E", "S", "W" } do
		local spec = params.sides[side]
		if spec ~= nil and spec.owned then
			buildWall(parent, params, result, side, if spec.open then DOOR_WIDTH else nil, DOOR_HEIGHT)
		end
	end

	local builder = VARIANT_BUILDERS[params.variant]
	if builder ~= nil then
		builder(parent, params, result)
	else
		warn(`[RoomKit] unknown variant "{params.variant}" — built bare room`)
	end

	return result
end

return RoomKit
