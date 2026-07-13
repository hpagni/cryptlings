--!strict
-- CRYPTLINGS: NIGHT SHIFT — FloorGenService (Stage 1 "Run loop", module floor-procgen).
-- Procedurally generates a greybox factory floor Model (named "Floor") under
-- the Workspace.NightShiftFloors Folder (R2 WP1.5 handle-ification):
--   * FLOOR_GRID_CELLS x FLOOR_GRID_CELLS grid of FLOOR_CELL_SIZE_STUDS rooms
--   * connectivity = seeded randomized-DFS spanning maze over the grid, then
--     15% of the remaining closed internal walls re-opened as loops (edges
--     touching the vault are excluded so the vault keeps exactly one entrance)
--   * loading dock fixed at the mid-south-edge cell (4,1): 4 "DockSpawn" pads,
--     the "ExtractDock" trigger volume, and a big closed shutter door
--   * zones by Manhattan distance from the dock — A <=2: Tier1 case anchors,
--     B 3..4: Tier2, C >=5: Tier3 plus exactly one Vault room. The vault door
--     is a locked Part tagged "VaultDoor" (opened by the Foreman's Key in
--     Stage 6); the vault pedestal anchor is tagged "VaultCaseSpawn" with
--     attribute Tier = 3 and is deliberately NOT tagged "CaseSpawn" so the
--     regular case spawner never fills it.
--   * CollectionService tags: "CaseSpawn" (attribute Tier), "PatrolNode" (one
--     per regular room — 34 on a 6x6 grid, >=12 required, spread across all
--     zones by construction), "VaultDoor", "VaultCaseSpawn"
--   * INTEGRATION DECISION (Stage 1 integrator): both tag sets stay, and the
--     RUNTIME-CANONICAL set is the alias set — "FloorSpawn" (dock pads),
--     "ExtractionDock" (trigger volume), "CaseAnchor" + attribute "CaseTier"
--     (case spawn points) — because ShiftService, ExtractionService and
--     CaseService all consume it. "CaseSpawn"/"Tier"/"PatrolNode"/"VaultDoor"
--     remain per the floor-procgen spec for tooling and future modules.
--     CaseService spawns from "CaseAnchor" ONLY (verified — no double-spawn);
--     any future case spawner must keep consuming exactly that one tag.
--   * each floor is centered at its opts.origin (default (1200, 0, 1200)) —
--     far from the hub, which Stage 1's ShiftService anchors at the world
--     origin; R2 concurrent sessions pass distinct 2000-stud-pitch origins
--   * global Lighting delegated to LobbyBuild/LobbyLighting (single owner,
--     SOP §2) + sparse flickering ceiling PointLights (local, owned here)
--   * §3.2 guarantee: >=1 Tier1 anchor within 2 rooms (room-graph BFS) of the
--     dock. Any room at graph distance <=2 is also at Manhattan distance <=2
--     (zone A -> Tier1) and every regular room gets >=1 anchor, so this holds
--     by construction; a runtime check force-injects one anyway if violated.
--
-- Determinism: Generate(seed, opts?) consumes a single Random.new(seed) stream
-- in a fixed iteration order; per-room cosmetic rng is forked into child
-- Randoms. Same seed -> identical part count, room graph and layout signature.
-- The per-room lightRoll is ALWAYS drawn (even when the scaled light chance
-- skips the fixture) so the rng stream stays aligned — determinism is
-- f(seed, lightDensityScale). Light flicker animates from os.clock and never
-- affects layout.
--
-- StreamingEnabled: Workspace.StreamingEnabled is NotScriptable at runtime, so
-- the pcall below is expected to fail outside Studio plugins. DOCUMENTED
-- FALLBACK: the integrator must set StreamingEnabled = true on Workspace via
-- default.project.json ($properties on a managed Workspace node) or once in
-- Studio before publishing (mobile gate, SOP §3.2).
--
-- Public API (R2 WP1.5 handle-ification — Change-6 migration step 1; the
-- WP6.1 facade cleanup removed the last-handle module state and the five
-- back-compat shim functions that delegated to it — every consumer reads the
-- returned FloorHandle's fields and tears down via handle:Destroy(); sibling
-- services that still feature-detect the old single-floor getters simply fall
-- back to their own tag scans. Nothing runs at boot beyond lighting config —
-- floor gen is deferred per the <45s join-to-playing gate):
--   FloorGenService.Generate(seed: number, opts: GenerateOptions?) -> FloorHandle
--     opts = { origin: Vector3?, sessionId: string?, lightDensityScale: number? }
--     FloorHandle = { model, spawnCFrame, dockSpawns, extractZone, signature,
--                     roomGraph, Destroy() }
--     Re-entrant: every call builds an independent floor at opts.origin,
--     parented under the on-demand Workspace.NightShiftFloors Folder with the
--     model attribute "SessionId" stamped (opts.sessionId or ""). The 1-arg
--     Generate(seed) call keeps working for ShiftService's legacy no-pad
--     fallback path (default origin (1200, 0, 1200) — unchanged single-floor
--     behavior). The flicker connection + lights list live in the handle and
--     are torn down by handle:Destroy(). Floor-internal lights are raw
--     Instance.new (never the lobby build kit) so they never enter the lobby
--     light tally.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConstants = require(Shared:WaitForChild("Config"):WaitForChild("GameConstants"))
local FloorLightPlan = require(Shared:WaitForChild("Logic"):WaitForChild("FloorLightPlan"))
local RoomKit = require(script.Parent:WaitForChild("FloorGen"):WaitForChild("RoomKit"))

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

local GRID: number = GameConstants.FLOOR_GRID_CELLS -- 6
local CELL: number = GameConstants.FLOOR_CELL_SIZE_STUDS -- 36
local PART_BUDGET: number = GameConstants.PART_BUDGET_FLOOR -- 3000

-- Greybox level-art numbers (geometry only — gameplay tunables live in
-- GameConstants per contract G).
local WALL_HEIGHT = 16
local EXTRA_OPENING_RATIO = 0.15 -- share of remaining closed internal walls re-opened as loops
local DOCK_GX, DOCK_GY = 4, 1 -- fixed mid-edge cell (south edge of the grid)
local DOCK_OUTER_SIDE = "S"
local ZONE_A_MAX_DIST = 2 -- Manhattan; -> Tier1
local ZONE_B_MAX_DIST = 4 -- Manhattan; -> Tier2 (beyond -> Tier3 / zone C)
local FIRST_CASE_GRAPH_DIST = 2 -- §3.2 / TIME_TO_FIRST_CASE_SECONDS guarantee radius
local MIN_PATROL_NODES = 12
-- R6 Fix #1: the old per-room coin-flip light chance (LIGHT_ROOM_CHANCE 0.55) and
-- FLICKER_CHANCE (0.5) are superseded by FloorLightPlan (deterministic, count-based
-- lit set with a >=50% floor + orange/purple night-lights). See FloorLightPlan.luau.
local FLICKER_STEP_SECONDS = 0.1

local TAG_CASE_SPAWN = "CaseSpawn"
local TAG_PATROL_NODE = "PatrolNode"
local TAG_VAULT_DOOR = "VaultDoor"
local TAG_VAULT_CASE_SPAWN = "VaultCaseSpawn"
local ATTR_TIER = "Tier"

-- Aliases for the convention ShiftService/ExtractionService shipped with in
-- parallel (see header). Read-only lookups on their side, so dual-tagging is
-- safe — except case spawners, which must pick ONE case tag.
local TAG_FLOOR_SPAWN_ALIAS = "FloorSpawn"
local TAG_EXTRACTION_DOCK_ALIAS = "ExtractionDock"
local TAG_CASE_ANCHOR_ALIAS = "CaseAnchor"
local ATTR_CASE_TIER_ALIAS = "CaseTier"

-- Default floor origin when Generate is called without opts.origin (legacy
-- 1-arg path) — far from the hub, which ShiftService anchors at the world
-- origin. R2 concurrent sessions pass slot origins at a 2000-stud pitch.
local DEFAULT_FLOOR_ORIGIN = Vector3.new(1200, 0, 1200)

-- Model attribute + container Folder for session-scoped floors (R2 Change 6).
local ATTR_SESSION_ID = "SessionId"
local FLOORS_FOLDER_NAME = "NightShiftFloors"

-- Fixed neighbor iteration order — part of the determinism contract.
local DIR_OFFSETS: { { side: string, dx: number, dy: number } } = {
	{ side = "N", dx = 0, dy = 1 },
	{ side = "E", dx = 1, dy = 0 },
	{ side = "S", dx = 0, dy = -1 },
	{ side = "W", dx = -1, dy = 0 },
}

local SIDE_DIRECTIONS: { [string]: Vector3 } = {
	N = Vector3.new(0, 0, 1),
	S = Vector3.new(0, 0, -1),
	E = Vector3.new(1, 0, 0),
	W = Vector3.new(-1, 0, 0),
}

--------------------------------------------------------------------------------
-- Handles (R2 WP1.5 — the module-level state table is gone; every Generate
-- returns an independent, self-tearing-down FloorHandle)
--------------------------------------------------------------------------------

type FlickerLight = { light: PointLight, base: number, phase: number, freq: number }

export type GenerateOptions = {
	origin: Vector3?,
	sessionId: string?,
	lightDensityScale: number?,
}

export type FloorHandle = {
	model: Model,
	spawnCFrame: CFrame,
	dockSpawns: { BasePart },
	extractZone: BasePart?,
	signature: string,
	roomGraph: { [string]: boolean },
	Destroy: (self: FloorHandle) -> (),
}

--------------------------------------------------------------------------------
-- Grid helpers
--------------------------------------------------------------------------------

local function cellId(gx: number, gy: number): number
	return (gy - 1) * GRID + gx
end

local function cellCoords(id: number): (number, number)
	local gx = (id - 1) % GRID + 1
	local gy = math.floor((id - 1) / GRID) + 1
	return gx, gy
end

-- World-space center of a cell on the floor-top plane; grid centered on the
-- floor origin (away from the hub at the world origin).
local function cellCenter(origin: Vector3, gx: number, gy: number): Vector3
	local originOffset = (GRID * CELL) / 2
	return origin + Vector3.new((gx - 0.5) * CELL - originOffset, 0, (gy - 0.5) * CELL - originOffset)
end

local function manhattanFromDock(gx: number, gy: number): number
	return math.abs(gx - DOCK_GX) + math.abs(gy - DOCK_GY)
end

local function zoneTier(gx: number, gy: number): number
	local dist = manhattanFromDock(gx, gy)
	if dist <= ZONE_A_MAX_DIST then
		return 1
	elseif dist <= ZONE_B_MAX_DIST then
		return 2
	end
	return 3
end

local function edgeKey(a: number, b: number): string
	if a < b then
		return a .. "_" .. b
	end
	return b .. "_" .. a
end

--------------------------------------------------------------------------------
-- Maze / room graph
--------------------------------------------------------------------------------

-- Randomized-DFS spanning maze rooted at the dock. Returns the open-edge set
-- and per-cell tree degree (for leaf detection).
--------------------------------------------------------------------------------
-- Decoration pass (greybox set dressing): 0-3 random factory props per regular
-- room, placed on a ring around the room center so doorways, the patrol-node
-- walk target, and case anchors stay clear. Deterministic per floorSeed (same
-- rng as the rest of generation); a few parts per decorated room, well inside
-- PART_BUDGET_FLOOR.
--------------------------------------------------------------------------------

local DECOR_ROOM_CHANCE = 0.7 -- share of regular rooms that get any props
local DECOR_MIN_RADIUS = 6 -- ring placement: clear of the room-center patrol target
local DECOR_MAX_RADIUS = 12 -- ...and of walls/doorways (CELL/2 = 18)

local DECOR_CRATE_COLOR = Color3.fromRGB(104, 88, 70) -- darker than case cardboard: never reads as loot
local DECOR_PALLET_COLOR = Color3.fromRGB(120, 90, 60)
local DECOR_DRUM_COLOR = Color3.fromRGB(86, 96, 110)
local DECOR_STRIPE_COLOR = Color3.fromRGB(235, 190, 52)
local DECOR_SCRAP_COLORS = {
	Color3.fromRGB(85, 170, 85),
	Color3.fromRGB(60, 120, 216),
	Color3.fromRGB(140, 80, 200),
	Color3.fromRGB(200, 90, 70),
}

local function decorPart(parent: Instance, name: string, size: Vector3, cframe: CFrame, color: Color3): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.Size = size
	part.CFrame = cframe
	part.Color = color
	part.Material = Enum.Material.SmoothPlastic
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

-- Each builder drops one prop at `base` (a ground point) with random spin.
local DECOR_BUILDERS: { (parent: Instance, rng: Random, base: Vector3) -> () } = {
	-- Crate stack: 1-3 mismatched boxes.
	function(parent, rng, base)
		local y = 0
		for _ = 1, rng:NextInteger(1, 3) do
			local side = rng:NextNumber(2.2, 3.4)
			local height = rng:NextNumber(1.8, 2.6)
			decorPart(
				parent,
				"DecorCrate",
				Vector3.new(side, height, side),
				CFrame.new(base + Vector3.new(rng:NextNumber(-0.5, 0.5), y + height / 2, rng:NextNumber(-0.5, 0.5)))
					* CFrame.Angles(0, rng:NextNumber(0, math.pi * 2), 0),
				DECOR_CRATE_COLOR
			)
			y += height
		end
	end,
	-- Wooden pallet, sometimes with a flat load.
	function(parent, rng, base)
		decorPart(
			parent,
			"DecorPallet",
			Vector3.new(6, 0.5, 6),
			CFrame.new(base + Vector3.new(0, 0.25, 0)) * CFrame.Angles(0, rng:NextNumber(0, math.pi * 2), 0),
			DECOR_PALLET_COLOR
		)
		if rng:NextNumber() < 0.5 then
			decorPart(
				parent,
				"DecorPalletLoad",
				Vector3.new(4, 1.4, 4),
				CFrame.new(base + Vector3.new(0, 1.2, 0)),
				DECOR_CRATE_COLOR
			)
		end
	end,
	-- Steel drum with a hazard band.
	function(parent, _rng, base)
		local lie = CFrame.new(base + Vector3.new(0, 1.8, 0)) * CFrame.Angles(0, 0, math.rad(90))
		local drum = decorPart(parent, "DecorDrum", Vector3.new(3.6, 2.6, 2.6), lie, DECOR_DRUM_COLOR)
		drum.Shape = Enum.PartType.Cylinder
		local band = decorPart(parent, "DecorDrumBand", Vector3.new(0.5, 2.7, 2.7), lie, DECOR_STRIPE_COLOR)
		band.Shape = Enum.PartType.Cylinder
		band.CanCollide = false
	end,
	-- Misprint toy scrap: 2-4 small bright rejects spilled on the floor.
	function(parent, rng, base)
		for _ = 1, rng:NextInteger(2, 4) do
			local size = rng:NextNumber(0.6, 1.3)
			local part = decorPart(
				parent,
				"DecorScrap",
				Vector3.new(size, size, size),
				CFrame.new(base + Vector3.new(rng:NextNumber(-2.5, 2.5), size / 2, rng:NextNumber(-2.5, 2.5)))
					* CFrame.Angles(0, rng:NextNumber(0, math.pi * 2), 0),
				DECOR_SCRAP_COLORS[rng:NextInteger(1, #DECOR_SCRAP_COLORS)]
			)
			part.CanCollide = false
			if rng:NextNumber() < 0.5 then
				part.Shape = Enum.PartType.Ball
			end
		end
	end,
	-- Dead conveyor stub.
	function(parent, rng, base)
		local yaw = CFrame.Angles(0, rng:NextNumber(0, math.pi * 2), 0)
		decorPart(
			parent,
			"DecorConveyor",
			Vector3.new(9, 1.6, 3.2),
			CFrame.new(base + Vector3.new(0, 0.8, 0)) * yaw,
			Color3.fromRGB(52, 54, 60)
		)
		local stripe = decorPart(
			parent,
			"DecorConveyorStripe",
			Vector3.new(9.2, 0.2, 0.6),
			CFrame.new(base + Vector3.new(0, 1.7, 0)) * yaw,
			DECOR_STRIPE_COLOR
		)
		stripe.CanCollide = false
	end,
}

local function decorateRoom(parent: Instance, rng: Random, center: Vector3)
	if rng:NextNumber() >= DECOR_ROOM_CHANCE then
		return
	end
	for _ = 1, rng:NextInteger(1, 3) do
		local angle = rng:NextNumber(0, math.pi * 2)
		local radius = rng:NextNumber(DECOR_MIN_RADIUS, DECOR_MAX_RADIUS)
		local base = center + Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
		DECOR_BUILDERS[rng:NextInteger(1, #DECOR_BUILDERS)](parent, rng, base)
	end
end

local function generateMaze(rng: Random): ({ [string]: boolean }, { [number]: number })
	local openEdges: { [string]: boolean } = {}
	local degree: { [number]: number } = {}
	for id = 1, GRID * GRID do
		degree[id] = 0
	end

	local dockId = cellId(DOCK_GX, DOCK_GY)
	local visited: { [number]: boolean } = { [dockId] = true }
	local stack = { dockId }

	while #stack > 0 do
		local current = stack[#stack]
		local cgx, cgy = cellCoords(current)
		local unvisited: { number } = {}
		for _, dir in DIR_OFFSETS do
			local nx, ny = cgx + dir.dx, cgy + dir.dy
			if nx >= 1 and nx <= GRID and ny >= 1 and ny <= GRID then
				local nid = cellId(nx, ny)
				if not visited[nid] then
					table.insert(unvisited, nid)
				end
			end
		end
		if #unvisited == 0 then
			table.remove(stack)
		else
			local nextId = unvisited[rng:NextInteger(1, #unvisited)]
			openEdges[edgeKey(current, nextId)] = true
			degree[current] += 1
			degree[nextId] += 1
			visited[nextId] = true
			table.insert(stack, nextId)
		end
	end

	return openEdges, degree
end

-- Exactly one Vault room: a spanning-tree leaf (single entrance) in zone C.
-- Every tree has a non-dock leaf; if no leaf reaches zone C on this seed,
-- fall back to the farthest leaves (documented deviation, warned).
local function pickVaultCell(rng: Random, degree: { [number]: number }): number
	local dockId = cellId(DOCK_GX, DOCK_GY)
	local leaves: { number } = {}
	local zoneCLeaves: { number } = {}
	for id = 1, GRID * GRID do
		if id ~= dockId and degree[id] == 1 then
			table.insert(leaves, id)
			local gx, gy = cellCoords(id)
			if manhattanFromDock(gx, gy) > ZONE_B_MAX_DIST then
				table.insert(zoneCLeaves, id)
			end
		end
	end

	local pool = zoneCLeaves
	if #pool == 0 then
		local best = -1
		for _, id in leaves do
			local gx, gy = cellCoords(id)
			best = math.max(best, manhattanFromDock(gx, gy))
		end
		pool = {}
		for _, id in leaves do
			local gx, gy = cellCoords(id)
			if manhattanFromDock(gx, gy) == best then
				table.insert(pool, id)
			end
		end
		warn(`[FloorGenService] no zone-C dead-end on this seed — vault placed at farthest leaf (dist {best})`)
	end
	return pool[rng:NextInteger(1, #pool)]
end

-- Re-opens 15% of the remaining closed internal walls as loops. Edges touching
-- the vault are excluded so it keeps its single (locked) entrance.
local function addExtraOpenings(rng: Random, openEdges: { [string]: boolean }, vaultId: number)
	local closed: { string } = {}
	for gy = 1, GRID do
		for gx = 1, GRID do
			local id = cellId(gx, gy)
			local function consider(nid: number)
				local key = edgeKey(id, nid)
				if not openEdges[key] and id ~= vaultId and nid ~= vaultId then
					table.insert(closed, key)
				end
			end
			if gx < GRID then
				consider(cellId(gx + 1, gy))
			end
			if gy < GRID then
				consider(cellId(gx, gy + 1))
			end
		end
	end

	for i = #closed, 2, -1 do
		local j = rng:NextInteger(1, i)
		closed[i], closed[j] = closed[j], closed[i]
	end
	local extra = math.floor(#closed * EXTRA_OPENING_RATIO + 0.5)
	for i = 1, extra do
		openEdges[closed[i]] = true
	end
end

-- BFS graph distance (in rooms) from the dock over open doorways.
local function bfsDistances(openEdges: { [string]: boolean }): { [number]: number }
	local dockId = cellId(DOCK_GX, DOCK_GY)
	local dist: { [number]: number } = { [dockId] = 0 }
	local queue = { dockId }
	local head = 1
	while head <= #queue do
		local current = queue[head]
		head += 1
		local cgx, cgy = cellCoords(current)
		for _, dir in DIR_OFFSETS do
			local nx, ny = cgx + dir.dx, cgy + dir.dy
			if nx >= 1 and nx <= GRID and ny >= 1 and ny <= GRID then
				local nid = cellId(nx, ny)
				if openEdges[edgeKey(current, nid)] and dist[nid] == nil then
					dist[nid] = dist[current] + 1
					table.insert(queue, nid)
				end
			end
		end
	end
	return dist
end

--------------------------------------------------------------------------------
-- Environment (lighting / streaming)
--------------------------------------------------------------------------------

-- WP4.2 (SOP §2): global Lighting is owned by ONE module — LobbyBuild/
-- LobbyLighting. The old body here (ClockTime 0, Brightness 0.6, dim ambients,
-- legacy fog) stomped the street look on every shift, and its fog clip would
-- have truncated the ~700-stud lobby street. Delegate to LobbyLighting.Apply();
-- if the module is absent (stripped test places), apply nothing — never
-- re-introduce fog. Per-floor flickering ceiling lights below are Light
-- instances, not Lighting globals, and stay owned by this service.
local function applyLightingConfig()
	local ok, lobbyLighting = pcall(function()
		local lobbyBuild = script.Parent:FindFirstChild("LobbyBuild")
		assert(lobbyBuild ~= nil, "LobbyBuild folder not found")
		local moduleScript = lobbyBuild:FindFirstChild("LobbyLighting")
		assert(moduleScript ~= nil and moduleScript:IsA("ModuleScript"), "LobbyLighting module not found")
		return require(moduleScript) :: any
	end)
	if ok and type(lobbyLighting) == "table" and type(lobbyLighting.Apply) == "function" then
		pcall(lobbyLighting.Apply)
	end
end

local function tryEnableStreaming()
	local ok = pcall(function()
		(workspace :: any).StreamingEnabled = true
	end)
	if not ok then
		warn(
			"[FloorGenService] Workspace.StreamingEnabled is not scriptable at runtime — "
				.. "set it via default.project.json ($properties) or once in Studio before publish "
				.. "(mobile gate, SOP §3.2)"
		)
	end
end

--------------------------------------------------------------------------------
-- Markers / lights
--------------------------------------------------------------------------------

-- Invisible anchored marker part (case anchors, patrol nodes).
local function createMarker(parent: Instance, name: string, position: Vector3): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.Size = Vector3.new(1, 1, 1)
	part.CFrame = CFrame.new(position)
	part.Transparency = 1
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.Parent = parent
	return part
end

local function createCaseAnchor(parent: Instance, position: Vector3, tier: number)
	local anchor = createMarker(parent, "CaseSpawn", position)
	anchor:SetAttribute(ATTR_TIER, tier)
	anchor:SetAttribute(ATTR_CASE_TIER_ALIAS, tier)
	CollectionService:AddTag(anchor, TAG_CASE_SPAWN)
	CollectionService:AddTag(anchor, TAG_CASE_ANCHOR_ALIAS)
end

-- Floor-internal lights are raw Instance.new on purpose (never the lobby
-- build kit's LightBudget-registered path) — they must never enter the lobby
-- light tally.
-- Overhead ceiling-fixture colors (R6 Fix #1) keyed by FloorLightPlan's
-- RoomLightKind. Warm-white stays the majority "factory emergency" tone; orange
-- and cyan are the deterministic variety accents.
local OVERHEAD_COLORS: { [string]: { number } } = {
	warm = { 255, 214, 170 },
	orange = { 255, 170, 120 },
	cyan = { 140, 220, 255 },
}

-- Night-light colors (R6 Fix #1) for unlit rooms — dim emergency glow so no
-- generic room is ever pitch black.
local NIGHT_COLORS: { [string]: { number } } = {
	orange = { 255, 150, 60 },
	purple = { 170, 90, 255 },
}

local function createRoomLight(
	lights: { FlickerLight },
	parent: Instance,
	position: Vector3,
	roll1: number,
	roll2: number,
	overheadColor: string,
	flicker: boolean
)
	local rgb = OVERHEAD_COLORS[overheadColor] or OVERHEAD_COLORS.warm
	local color = Color3.fromRGB(rgb[1], rgb[2], rgb[3])

	local fixture = Instance.new("Part")
	fixture.Name = "LightFixture"
	fixture.Anchored = true
	fixture.Size = Vector3.new(1.6, 0.4, 1.6)
	fixture.CFrame = CFrame.new(position)
	fixture.Color = color
	fixture.Material = Enum.Material.Neon
	fixture.CanCollide = false
	fixture.CanTouch = false
	fixture.CanQuery = false

	local light = Instance.new("PointLight")
	light.Color = color
	light.Brightness = 0.9 + roll1 * 0.5
	light.Range = 24
	light.Shadows = false -- mobile perf (§3.2)
	light.Parent = fixture
	fixture.Parent = parent

	if flicker then
		table.insert(lights, {
			light = light,
			base = light.Brightness,
			phase = roll1 * 2 * math.pi,
			-- R6 Fix #1d: slow 0.5-2 Hz unstable-fluorescent pulse (was 5-14 Hz
			-- strobe). Keeps the blackout pops in startFlicker.
			freq = 0.5 + roll2 * 1.5,
		})
	end
end

-- Dim colored night-light for an UNLIT room (R6 Fix #1b). Reuses the same
-- fixture geometry as createRoomLight (no coplanar duplicate parts, C-aesthetic
-- §no-z-fight). Night-lights never flicker (steady navigation anchor) so they
-- are never added to the flicker list.
local function createNightLight(parent: Instance, position: Vector3, nightColor: string)
	local rgb = NIGHT_COLORS[nightColor] or NIGHT_COLORS.orange
	local color = Color3.fromRGB(rgb[1], rgb[2], rgb[3])

	local fixture = Instance.new("Part")
	fixture.Name = "NightLightFixture"
	fixture.Anchored = true
	fixture.Size = Vector3.new(1.6, 0.4, 1.6)
	fixture.CFrame = CFrame.new(position)
	fixture.Color = color
	fixture.Material = Enum.Material.Neon
	fixture.CanCollide = false
	fixture.CanTouch = false
	fixture.CanQuery = false

	local light = Instance.new("PointLight")
	light.Color = color
	light.Brightness = 0.35
	light.Range = 16
	light.Shadows = false -- mobile perf (§3.2)
	light.Parent = fixture
	fixture.Parent = parent
end

-- Per-handle flicker loop; the returned connection lives in the handle and is
-- disconnected by handle:Destroy().
local function startFlicker(lights: { FlickerLight }): RBXScriptConnection?
	if #lights == 0 then
		return nil
	end
	local accum = 0
	return RunService.Heartbeat:Connect(function(dt: number)
		accum += dt
		if accum < FLICKER_STEP_SECONDS then
			return
		end
		accum = 0
		local now = os.clock()
		for _, entry in lights do
			local wave = math.sin(now * entry.freq + entry.phase)
				+ 0.6 * math.sin(now * entry.freq * 2.7 + entry.phase * 1.7)
			if wave > 1.45 then
				entry.light.Enabled = false -- brief blackout pop
			else
				entry.light.Enabled = true
				entry.light.Brightness = entry.base * (0.7 + 0.3 * math.clamp(wave, -1, 1))
			end
		end
	end)
end

--------------------------------------------------------------------------------
-- Layout signature (acceptance: same seed -> same part count + room graph)
--------------------------------------------------------------------------------

local function rollingHash(s: string): number
	local hash = 5381
	for i = 1, #s do
		hash = (hash * 31 + string.byte(s, i)) % 2147483647
	end
	return hash
end

--------------------------------------------------------------------------------
-- Service
--------------------------------------------------------------------------------

local FloorGenService = {}

-- On-demand container for session-scoped floors.
local function getFloorsFolder(): Folder
	local existing = workspace:FindFirstChild(FLOORS_FOLDER_NAME)
	if existing ~= nil and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = FLOORS_FOLDER_NAME
	folder.Parent = workspace
	return folder
end

-- Re-entrant floor build (R2 WP1.5): no module state is touched — concurrent
-- callers get independent, self-tearing-down handles.
function FloorGenService.Generate(seed: number, opts: GenerateOptions?): FloorHandle
	local options: GenerateOptions = opts or {}
	local origin = options.origin or DEFAULT_FLOOR_ORIGIN
	local sessionId = options.sessionId or ""
	local lightDensityScale = options.lightDensityScale or 1
	-- R6 Fix #1: per-room coin-flip light chance is superseded by FloorLightPlan
	-- (deterministic count-based lit set + night-light fill — see top-of-file note).

	applyLightingConfig()

	local rng = Random.new(seed)

	-- 1) Room graph: spanning maze -> vault pick -> loop openings -> distances.
	local openEdges, degree = generateMaze(rng)
	local vaultId = pickVaultCell(rng, degree)
	addExtraOpenings(rng, openEdges, vaultId)
	local dist = bfsDistances(openEdges)

	local dockId = cellId(DOCK_GX, DOCK_GY)
	local model = Instance.new("Model")
	model.Name = "Floor"
	local markers = Instance.new("Folder")
	markers.Name = "Markers"
	markers.Parent = model

	-- 2) Rooms (fixed iteration order; all rng draws happen for every cell so
	-- the stream stays aligned regardless of variant).
	local anchorCount = 0
	local patrolCount = 0
	local nearTier1 = false -- §3.2 guarantee tracker (graph dist <= 2)
	local variantById: { [number]: string } = {}
	local vaultResult: any = nil
	local vaultCenter = Vector3.zero
	local dockSpawns: { BasePart } = {}
	local extractZone: BasePart? = nil
	local flickerLights: { FlickerLight } = {}

	-- R6 Fix #1: collect per-generic-room lighting inputs DURING the loop (no new
	-- rng draws — reuses lightRoll/flickerRoll already drawn at fixed positions),
	-- then instantiate lights in a SECOND pass after the loop via FloorLightPlan.
	local genericRolls: { FloorLightPlan.RoomRoll } = {}
	type LightCell = { genericIndex: number, lightPosition: Vector3, lightRoll: number, flickerRoll: number }
	local lightCells: { LightCell } = {}

	local genericVariants: { string } = RoomKit.GENERIC_VARIANTS

	for gy = 1, GRID do
		for gx = 1, GRID do
			local id = cellId(gx, gy)
			local roomSeed = rng:NextInteger(0, 1073741823)
			local variantRoll = rng:NextInteger(1, #genericVariants)
			local lightRoll = rng:NextNumber()
			local flickerRoll = rng:NextNumber()
			local anchorWanted = rng:NextInteger(1, 2)

			local variant: string
			if id == dockId then
				variant = "Dock"
			elseif id == vaultId then
				variant = "Vault"
			else
				variant = genericVariants[variantRoll]
			end
			variantById[id] = variant

			-- Wall ownership: every cell owns N + E; boundary cells own their
			-- S (gy == 1) / W (gx == 1) walls too -> each edge built once.
			local sides: { [string]: { owned: boolean, open: boolean } } = {}
			for _, dir in DIR_OFFSETS do
				local nx, ny = gx + dir.dx, gy + dir.dy
				local inBounds = nx >= 1 and nx <= GRID and ny >= 1 and ny <= GRID
				local owned: boolean
				if dir.side == "N" or dir.side == "E" then
					owned = true
				elseif dir.side == "S" then
					owned = gy == 1
				else
					owned = gx == 1
				end
				local open = inBounds and openEdges[edgeKey(id, cellId(nx, ny))] == true
				sides[dir.side] = { owned = owned, open = open }
			end

			local outerSide: string? = nil
			if id == dockId then
				-- The dock builds its own shutter assembly on the outer edge.
				outerSide = DOCK_OUTER_SIDE
				sides[DOCK_OUTER_SIDE] = { owned = false, open = false }
			end

			local center = cellCenter(origin, gx, gy)
			local result = RoomKit.Build(model, {
				variant = variant,
				center = center,
				cellSize = CELL,
				wallHeight = WALL_HEIGHT,
				rng = Random.new(roomSeed),
				sides = sides,
				outerSide = outerSide,
			})

			if id == dockId then
				dockSpawns = result.dockSpawns
				extractZone = result.extractZone
				for _, pad in dockSpawns do
					CollectionService:AddTag(pad, TAG_FLOOR_SPAWN_ALIAS)
				end
				if extractZone ~= nil then
					CollectionService:AddTag(extractZone :: BasePart, TAG_EXTRACTION_DOCK_ALIAS)
				end
			elseif id == vaultId then
				vaultResult = result
				vaultCenter = center
			else
				-- Case anchors by Manhattan zone (A->1, B->2, C->3).
				local tier = zoneTier(gx, gy)
				local candidates: { Vector3 } = result.caseAnchorPositions
				local picked = math.min(#candidates, anchorWanted)
				if picked > 0 then
					-- Deterministic partial Fisher-Yates pick.
					local pool = table.clone(candidates)
					for i = #pool, 2, -1 do
						local j = rng:NextInteger(1, i)
						pool[i], pool[j] = pool[j], pool[i]
					end
					for i = 1, picked do
						createCaseAnchor(markers, pool[i], tier)
						anchorCount += 1
					end
					if tier == 1 and dist[id] ~= nil and dist[id] <= FIRST_CASE_GRAPH_DIST then
						nearTier1 = true
					end
				end

				-- One patrol node per regular room: 34 on a 6x6 grid, spread
				-- across every zone, all reachable (the maze spans the grid
				-- and the vault — excluded here — is a leaf).
				local node = createMarker(markers, "PatrolNode", center + Vector3.new(0, 2, 0))
				CollectionService:AddTag(node, TAG_PATROL_NODE)
				patrolCount += 1

				-- Random set dressing (regular rooms only — dock and vault stay clean).
				decorateRoom(model, rng, center)

				-- R6 Fix #1: record this generic room's lighting inputs (the
				-- lightRoll/flickerRoll already drawn above — no new draw). Lights
				-- are instantiated after the loop from FloorLightPlan so >=50% of
				-- generic rooms are deterministically overhead-lit and the rest get
				-- a colored night-light (no pitch-black room).
				table.insert(genericRolls, { light = lightRoll, flicker = flickerRoll })
				table.insert(lightCells, {
					genericIndex = #genericRolls,
					lightPosition = result.lightPosition,
					lightRoll = lightRoll,
					flickerRoll = flickerRoll,
				})
			end
		end
	end

	-- R6 Fix #1: deterministic lighting plan over the ACTUAL generic-room count.
	-- Touches no rng (only consumes the already-drawn rolls), so the seeded stream
	-- stays byte-identical to before — determinism is preserved.
	do
		local plan = FloorLightPlan.plan(seed, #genericRolls, lightDensityScale, genericRolls)
		for _, cell in lightCells do
			local roomPlan = plan.rooms[cell.genericIndex]
			if roomPlan.lit then
				createRoomLight(
					flickerLights,
					model,
					cell.lightPosition,
					cell.lightRoll,
					cell.flickerRoll,
					roomPlan.overheadColor or "warm",
					roomPlan.flicker
				)
			else
				createNightLight(model, cell.lightPosition, roomPlan.nightColor or "orange")
			end
		end
	end

	-- 3) Vault door (fill the vault's single doorway gap) + vault case anchor.
	do
		local vgx, vgy = cellCoords(vaultId)
		local openSides: { string } = {}
		for _, dir in DIR_OFFSETS do
			local nx, ny = vgx + dir.dx, vgy + dir.dy
			if nx >= 1 and nx <= GRID and ny >= 1 and ny <= GRID then
				if openEdges[edgeKey(vaultId, cellId(nx, ny))] then
					table.insert(openSides, dir.side)
				end
			end
		end
		if #openSides ~= 1 then
			warn(`[FloorGenService] vault has {#openSides} openings (expected exactly 1)`)
		end
		local side = openSides[1]
		if side ~= nil then
			local edgeCenter = vaultCenter + SIDE_DIRECTIONS[side] * (CELL / 2)
			local alongX = side == "N" or side == "S"
			local door = RoomKit.BuildDoorFill(model, edgeCenter, alongX, "VaultDoor")
			CollectionService:AddTag(door, TAG_VAULT_DOOR)
		end
		if vaultResult ~= nil and vaultResult.vaultAnchorPosition ~= nil then
			local anchor = createMarker(markers, "VaultCaseSpawn", vaultResult.vaultAnchorPosition)
			anchor:SetAttribute(ATTR_TIER, 3)
			CollectionService:AddTag(anchor, TAG_VAULT_CASE_SPAWN)
		end
	end

	-- 4) Ceiling slab over the whole floor (keeps the interior dark).
	do
		local span = GRID * CELL + 2
		local ceiling = Instance.new("Part")
		ceiling.Name = "Ceiling"
		ceiling.Anchored = true
		ceiling.Size = Vector3.new(span, 1, span)
		ceiling.CFrame = CFrame.new(origin + Vector3.new(0, WALL_HEIGHT + 0.5, 0))
		ceiling.Color = Color3.fromRGB(40, 40, 44)
		ceiling.Material = Enum.Material.Concrete
		ceiling.Parent = model
	end

	-- 5) §3.2 guarantee: >=1 Tier1 anchor within FIRST_CASE_GRAPH_DIST rooms of
	-- the dock (holds by construction; force-inject if a seed ever violates it).
	if not nearTier1 then
		for id = 1, GRID * GRID do
			if id ~= dockId and id ~= vaultId and dist[id] ~= nil and dist[id] <= FIRST_CASE_GRAPH_DIST then
				local gx, gy = cellCoords(id)
				createCaseAnchor(markers, cellCenter(origin, gx, gy) + Vector3.new(0, 1.5, 0), 1)
				anchorCount += 1
				warn("[FloorGenService] forced a Tier1 anchor near the dock (TIME_TO_FIRST_CASE guarantee)")
				break
			end
		end
	end

	-- 6) Acceptance checks: reachability + part budget + patrol spread.
	local reachableRooms = 0
	for _ in dist do
		reachableRooms += 1
	end
	if reachableRooms < GRID * GRID then
		warn(`[FloorGenService] room graph not fully connected: {reachableRooms}/{GRID * GRID} reachable`)
	end
	if patrolCount < MIN_PATROL_NODES then
		warn(`[FloorGenService] only {patrolCount} patrol nodes (need >= {MIN_PATROL_NODES})`)
	end

	local partCount = 0
	for _, inst in model:GetDescendants() do
		if inst:IsA("BasePart") then
			partCount += 1
		end
	end
	if partCount > PART_BUDGET then
		warn(`[FloorGenService] PART BUDGET EXCEEDED: {partCount} > {PART_BUDGET}`)
	end

	-- 7) Layout signature (sorted room-graph edges + variants + part count).
	local edgeList: { string } = {}
	for key in openEdges do
		table.insert(edgeList, key)
	end
	table.sort(edgeList)
	local variantList: { string } = {}
	for id = 1, GRID * GRID do
		table.insert(variantList, string.sub(variantById[id] or "?", 1, 2))
	end
	local signature = string.format(
		"seed=%d|parts=%d|vault=%d|graph=%s|variants=%s",
		seed,
		partCount,
		vaultId,
		table.concat(edgeList, ";"),
		table.concat(variantList, ".")
	)

	print(
		string.format(
			"[FloorGenService] seed=%d parts=%d/%d rooms=%d caseAnchors=%d patrolNodes=%d reachable=%d/%d layoutHash=%d",
			seed,
			partCount,
			PART_BUDGET,
			GRID * GRID,
			anchorCount,
			patrolCount,
			reachableRooms,
			GRID * GRID,
			rollingHash(signature)
		)
	)

	-- Spawn point: first dock pad (matches ShiftService's historical pick), or
	-- a dock-cell-adjacent fallback when a seed somehow yields no pads.
	local spawnCFrame: CFrame
	if #dockSpawns > 0 then
		spawnCFrame = dockSpawns[1].CFrame + Vector3.new(0, 4, 0)
	else
		spawnCFrame = CFrame.new(origin + Vector3.new(18, 5, 18))
	end

	tryEnableStreaming()
	model:SetAttribute(ATTR_SESSION_ID, sessionId)
	model.Parent = getFloorsFolder()
	local flickerConn = startFlicker(flickerLights)

	local destroyed = false
	local handle: FloorHandle = {
		model = model,
		spawnCFrame = spawnCFrame,
		dockSpawns = dockSpawns,
		extractZone = extractZone,
		signature = signature,
		roomGraph = openEdges,
		Destroy = function(_self: FloorHandle)
			if destroyed then
				return
			end
			destroyed = true
			if flickerConn ~= nil then
				flickerConn:Disconnect()
				flickerConn = nil
			end
			table.clear(flickerLights)
			model:Destroy()
		end,
	}
	return handle
end

-- Loader lifecycle: the SOP §2 night look is (re)applied at boot via
-- LobbyLighting; floor generation itself is deferred to ShiftService
-- (join-to-playing < 45s, §3.2).
function FloorGenService.Init()
	applyLightingConfig()
end

return FloorGenService
