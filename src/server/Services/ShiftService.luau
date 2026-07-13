--!strict
-- CRYPTLINGS: NIGHT SHIFT — ShiftService (R2 WP5.2: SessionManager facade,
-- metronome dispatcher + 5-origin slot pool; Lobby SOP Addendum 1 Change 6.2,
-- migration step 4; WP6.1 facade cleanup: floors are consumed exclusively as
-- FloorGenService FloorHandles — the pre-handle shape wrapping is retired).
-- The run-loop FSM that lived at module level here is now Services/Shift/
-- ShiftSession (one instance per shift). ShiftService keeps its name and its
-- public API as a facade: per-player calls route through the playerToSession
-- reverse index; global calls aggregate over `sessions`. The dispatcher
-- consumes the metronome pad's pending FIFO bins (DispatchCore plans them;
-- QueuePadService snapshots at T=0) and launches ONE ShiftSession per bin
-- from the LobbyConfig.DISPATCH slot pool — two same-tick bins (6 occupants
-- -> 4+2) launch the same tick at distinct 2000-stud-pitch origins. Max
-- SLOT_COUNT (5) concurrent sessions, enforced HERE by pool exhaustion
-- regardless of pad traffic; an all-busy pool defers that bin alone (the pad
-- shows "ALL FLOORS RUNNING").
--
-- Public API (contract I + Stage 1 siblings; facade-routed, signatures unchanged):
--   ShiftService.GetPayMultiplier(player) -> number   -- x2 with PASS_2X_PAY (pcall-safe, default 1)
--   ShiftService.DownPlayer(player)                   -- DefectService/CombatService; routes via playerToSession
--   ShiftService.IsDowned(player) -> boolean
--   ShiftService.RevivePlayer(player) -> boolean      -- Stage 6: ConsumableService's revive beacon
--   ShiftService.GetState() -> "Intermission" | "Active" | "Complete"  -- any-session aggregate
--   ShiftService.IsActive() -> boolean                -- true while ANY session is Active
--   ShiftService.GetShiftId() -> string?              -- compat: arbitrary live session (Active preferred) — prefer GetShiftIdFor
--   ShiftService.GetFloorRoot() -> Instance?          -- compat: arbitrary live session — prefer GetFloorRootFor
--   ShiftService.IsParticipant(player) -> boolean
--   ShiftService.HasExtracted(player) -> boolean
--   ShiftService.MarkExtracted(player)                -- ExtractionService; returns the player to the hub
--   ShiftService.ReturnToHub(player)
--   ShiftService.GetHubSpawnPosition() -> Vector3
--   ShiftService.NoteServerTeleport(player)           -- re-seeds the movement validator
-- R2 additive session API (Change 6.2.2; consumers feature-detect via pcall):
--   ShiftService.GetSessionOf(player) -> ShiftSession?
--   ShiftService.GetFloorRootFor(player) -> Instance?
--   ShiftService.GetShiftIdFor(player) -> string?
--   ShiftService.GetFreeSlotCount() -> number         -- free slots in the 5-origin pool (WP5.2; the pad plans deferred bins off it)
--
-- Event scoping (Change 6.6): ShiftState carries an additive sessionId and
-- participants receive their OWN session's shiftEndsAt; PlayerDownedState is
-- delivered per-session-roster FireClient ONLY (never an all-clients
-- broadcast) with the additive sessionId — downed/bleedout state never leaks
-- across concurrent sessions. Every server-initiated move this file owns (dispatch pivot,
-- MarkExtracted -> ReturnToHub, complete-shift returns) re-seeds the movement
-- validator via NoteServerTeleport.
--
-- Optional siblings consumed via pcall-require (all degrade gracefully when
-- absent):
--   RotationService.GetNightlySeed() -> number
--   FloorGenService.Generate(seed, opts?) -> FloorHandle (R2 WP1.5; WP6.1
--     retired the pre-handle shapes/shims — a non-handle result falls through
--     to the local greybox fallback floor).
--     The floor must CollectionService-tag: "FloorSpawn" (crew spawn pad),
--     "ExtractionDock" (dock trigger part), "CaseAnchor" (case spawn points,
--     optional numeric attribute "CaseTier" 1..3).
--   HubService.GetSpawnPosition() -> Vector3
--   HubService.GetClockInZone() -> BasePart? / HubService.IsInClockInZone(player)
--   DefectService.OnShiftActive(floorRoot) / DefectService.OnShiftEnded()
--     (legacy fallbacks OnShiftStart(floorRoot, seed) / OnShiftEnd() also tried)
--   MonetizationService.OwnsPass(player, sku) -> boolean
--   QueuePadService.GetPendingDispatch()/ConsumeDispatch() -> { { Player } }?,
--   AddRequeueVote(player), ReportAfkStrike(player)
--     (WP5.1 metronome pad: GetPendingDispatch is non-nil exactly at T=0 with
--      >= 1 bin — and on a unanimous start-now vote; this service consumes the
--      party-aware FIFO bins (each <= DISPATCH.BIN_SIZE) and launches one
--      session per bin. ReportAfkStrike feeds the pad's 2-strike cooldown.
--      Absent or degraded, the legacy fixed countdown below stays in charge.)

local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConstants = require(Shared:WaitForChild("Config"):WaitForChild("GameConstants"))
local LobbyConfig = require(Shared:WaitForChild("Config"):WaitForChild("LobbyConfig"))
local Remotes = require(Shared:WaitForChild("Net"):WaitForChild("Remotes"))

-- Folder module (NOT auto-loaded — the Stage-0 loader only requires direct
-- ModuleScript children of Services/); same pattern as FloorGen/RoomKit.
local ShiftSession = require(script.Parent:WaitForChild("Shift"):WaitForChild("ShiftSession"))

type Session = ShiftSession.ShiftSession
type FloorLike = ShiftSession.FloorLike

--------------------------------------------------------------------------------
-- Stage-1 local tuning (not in GameConstants v1 — candidates for promotion;
-- flagged to the integrator)
--------------------------------------------------------------------------------

-- Fallback-only queue radius: used when HubService (and its CLOCK IN zone) is
-- absent/broken and the greybox fallback pad is the hub. With HubService alive,
-- the queue gate is the exact CLOCK IN zone (HubService.IsInClockInZone).
local INTERMISSION_ZONE_RADIUS_STUDS = 60
local PAD_DISPATCH_POLL_SECONDS = 0.25 -- WP5.2: GetPendingDispatch poll cadence while the metronome pad is live
local REQUEUE_FORWARD_COOLDOWN_SECONDS = 1 -- WP4.1: per-player bound on forwarding RequeueShift to the pad
local HUB_FALLBACK_POSITION = Vector3.new(0, 4, 0)

-- WP5.2 dispatcher numbers of record (Change 6.2.3): CYCLE/BIN_SIZE/SLOT_*
-- all live in LobbyConfig.DISPATCH — never literals here. Slot N origin =
-- Vector3.new(1200 + (slot - 1) * 2000, 0, 1200), i.e. SLOT_BASE stepped by
-- SLOT_PITCH_STUDS (2000) on X only: the pitch exceeds streaming/light/audio
-- range and the shared Y lets ONE Lighting config serve every floor.
local DISPATCH = LobbyConfig.DISPATCH
local SESSION_WAIT_POLL_SECONDS = 0.25 -- legacy no-pad path: single-session teardown wait

-- Change 6.7 streaming hygiene: bound the per-player pre-stream pull so a
-- stalled client can never delay a launch indefinitely (PivotTo proceeds
-- regardless — streaming-in is best-effort).
local STREAM_PULL_TIMEOUT_SECONDS = 5

-- In-shift AFK watchdog (Change 6.1.6) sampling: the windows/thresholds are
-- DISPATCH.INSHIFT_* / GROUP_IDLE_TEARDOWN_SECONDS; these two only shape the
-- sampler itself.
local AFK_WATCHDOG_TICK_SECONDS = 5
local AFK_ACTIVITY_EPSILON_STUDS = 2 -- per-tick root drift below this = "not moving"

-- CollectionService tags shared with FloorGenService / CaseService / ExtractionService.
local TAG_FLOOR_SPAWN = "FloorSpawn"
local TAG_EXTRACTION_DOCK = "ExtractionDock"
local TAG_CASE_ANCHOR = "CaseAnchor"

--------------------------------------------------------------------------------
-- Lazy sibling resolution (pcall-require; missing modules degrade gracefully)
--------------------------------------------------------------------------------

local siblingCache: { [string]: any } = {}

local function getSibling(name: string): any
	local cached = siblingCache[name]
	if cached ~= nil then
		if cached == false then
			return nil
		end
		return cached
	end
	local container = script.Parent
	local module = container and container:FindFirstChild(name)
	local result: any = nil
	if module ~= nil and module:IsA("ModuleScript") then
		local ok, required = pcall(require, module)
		if ok and type(required) == "table" then
			result = required
		end
	end
	siblingCache[name] = if result ~= nil then result else false
	return result
end

local function track(player: Player, event: string, props: { [string]: any }?)
	local analytics = getSibling("AnalyticsService")
	if analytics ~= nil and type(analytics.Track) == "function" then
		pcall(analytics.Track, player, event, props)
	end
end

--------------------------------------------------------------------------------
-- State (SessionManager): the per-shift FSM lives in ShiftSession instances
--------------------------------------------------------------------------------

local ShiftService = {}

local sessions: { [string]: Session } = {}
local playerToSession: { [Player]: Session } = {}

local shiftCounter = 0
local intermissionEndsAt: number? = nil -- legacy fixed-countdown deadline (nil on the pad path)
local hubSpawnPosition: Vector3 = HUB_FALLBACK_POSITION

local requeueVotes: { [Player]: boolean } = {}

local shiftStateRemote: RemoteEvent? = nil
local downedStateRemote: RemoteEvent? = nil

local hubRng = Random.new()

-- Single-session compat reads (GetShiftId/GetFloorRoot + bystander payloads):
-- an arbitrary representative once N > 1 — Active sessions preferred so the
-- aggregate state never under-reports a live shift. Per-player consumers must
-- use the *For variants (playerToSession), never this.
local function anySession(): Session?
	local fallback: Session? = nil
	for _, session in sessions do
		if session.state == "Active" then
			return session
		end
		if fallback == nil then
			fallback = session
		end
	end
	return fallback
end

--------------------------------------------------------------------------------
-- Slot pool (Change 6.2.3 — WP5.2): DISPATCH.SLOT_COUNT (5) fixed floor
-- origins at the DISPATCH.SLOT_PITCH_STUDS (2000) pitch. A slot is acquired
-- before floor generation and released ONLY after ShiftSession:Destroy() has
-- torn the floor model down (see onSessionDestroyed), so an origin is never
-- re-issued under a dying floor and a crashed session never leaks its slot.
--------------------------------------------------------------------------------

local slotBusy: { [number]: boolean } = {}

-- Slot N origin = Vector3.new(1200 + (slot - 1) * 2000, 0, 1200) — SLOT_BASE
-- stepped by SLOT_PITCH_STUDS (2000) on X only (one Lighting config, no
-- cross-floor streaming/light/audio reach; max offset 9.2k studs).
local function slotOrigin(slot: number): Vector3
	local base = DISPATCH.SLOT_BASE
	return Vector3.new(base.X + (slot - 1) * DISPATCH.SLOT_PITCH_STUDS, base.Y, base.Z)
end

local function acquireSlot(): number?
	for slot = 1, DISPATCH.SLOT_COUNT do
		if slotBusy[slot] ~= true then
			slotBusy[slot] = true
			return slot
		end
	end
	-- All 5 busy (only possible with stuck sessions): that bin alone defers —
	-- the pad billboard shows "ALL FLOORS RUNNING" (it plans against
	-- GetFreeSlotCount) and the occupants ride the next cycle.
	return nil
end

local function releaseSlot(slot: number)
	slotBusy[slot] = nil
end

--------------------------------------------------------------------------------
-- Broadcasting
--------------------------------------------------------------------------------

-- Each client also learns whether THEY are mid-run (payload.participant):
-- hub bystanders keep the shop through shifts they never clocked into —
-- §4.1's "never sell mid-run" is about runners, not spectators.
-- Participants get THEIR session's payload; bystanders get the any-session
-- aggregate (with the cap at 1, exactly the old global payload).
local function sendStateTo(player: Player)
	if shiftStateRemote == nil then
		return
	end
	local session = playerToSession[player] or anySession()
	local payload: { [string]: any }
	if session ~= nil then
		payload = {
			state = session.state,
			floorSeed = session.seed,
			shiftEndsAt = session.stateEndsAt, -- participants get THEIR session's deadline
			shiftId = session.id,
			sessionId = session.id, -- R2 additive (Change 6.6); clients drop mismatches
			participant = session:IsParticipant(player) and not session:HasExtracted(player),
		}
	else
		payload = {
			state = "Intermission",
			shiftEndsAt = intermissionEndsAt,
			participant = false,
		}
	end
	shiftStateRemote:FireClient(player, payload)
end

local function broadcastState()
	for _, player in Players:GetPlayers() do
		sendStateTo(player)
	end
end

-- Downed/bleedout state fan-out: per-session-roster FireClient ONLY (Change
-- 6.6 — the old all-clients broadcast leaked bleedout rings across
-- sessions). The downed player is still on the roster at every fire site
-- (clear-paths fire BEFORE roster removal), so they always hear their own
-- state; clients additionally drop mismatched sessionIds defensively.
local function fireDownedStateFor(session: Session, player: Player, downed: boolean, position: Vector3?)
	if downedStateRemote == nil then
		return
	end
	local payload: { [string]: any } = {
		userId = player.UserId,
		downed = downed,
		sessionId = session.id, -- R2 additive (Change 6.6)
	}
	if position ~= nil then
		payload.position = { position.X, position.Y, position.Z }
	end
	if downed then
		-- Lets the client render the bleedout ring without hardcoding the
		-- duration (server may vary it later, e.g. revive beacons).
		payload.bleedoutSeconds = GameConstants.DOWNED_BLEEDOUT_SECONDS
	end
	local remote = downedStateRemote :: RemoteEvent
	for member in session.participants do
		if member.Parent == Players then
			remote:FireClient(member, payload)
		end
	end
end

--------------------------------------------------------------------------------
-- Hub spawn (HubService if present, else a greybox baseplate pad). The pad
-- branch is intentionally KEPT even though HubService now always provides the
-- spawn: it is the degrade-gracefully path for test places / a broken hub
-- (house rule: optional siblings never take the run loop down with them).
--------------------------------------------------------------------------------

local function ensureHubSpawn()
	local hub = getSibling("HubService")
	if hub ~= nil and type(hub.GetSpawnPosition) == "function" then
		local ok, position = pcall(hub.GetSpawnPosition)
		if ok and typeof(position) == "Vector3" then
			hubSpawnPosition = position
			return
		end
	end

	if Workspace:FindFirstChild("NightShiftHub") == nil then
		local folder = Instance.new("Folder")
		folder.Name = "NightShiftHub"

		local pad = Instance.new("SpawnLocation")
		pad.Name = "HubPad"
		pad.Size = Vector3.new(48, 1, 48)
		pad.CFrame = CFrame.new(HUB_FALLBACK_POSITION.X, 0.5, HUB_FALLBACK_POSITION.Z)
		pad.Anchored = true
		pad.Neutral = true
		pad.Duration = 0
		pad.Color = Color3.fromRGB(70, 70, 78)
		pad.TopSurface = Enum.SurfaceType.Smooth
		pad.BottomSurface = Enum.SurfaceType.Smooth
		pad.Parent = folder

		folder.Parent = Workspace
	end
	hubSpawnPosition = HUB_FALLBACK_POSITION
end

function ShiftService.GetHubSpawnPosition(): Vector3
	return hubSpawnPosition
end

function ShiftService.ReturnToHub(player: Player)
	local character = player.Character
	if character == nil then
		return
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if root ~= nil and root:IsA("BasePart") then
		root.Anchored = false
	end
	local angle = hubRng:NextNumber(0, math.pi * 2)
	local offset = Vector3.new(math.cos(angle) * 4, 2, math.sin(angle) * 4)
	character:PivotTo(CFrame.new(hubSpawnPosition + offset))
	-- Change 6.6 teleport hygiene: every server-initiated move re-seeds the
	-- movement validator (covers MarkExtracted and complete-shift returns).
	ShiftService.NoteServerTeleport(player)
end

--------------------------------------------------------------------------------
-- Fallback greybox floor (used only while FloorGenService is absent/broken;
-- all geometry from Parts at runtime, well under PART_BUDGET_FLOOR)
--------------------------------------------------------------------------------

local function makePart(parent: Instance, name: string, size: Vector3, cframe: CFrame, color: Color3): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.Size = size
	part.CFrame = cframe
	part.Color = color
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

local function buildFallbackFloor(seed: number, parent: Instance, origin: Vector3): Instance
	local rng = Random.new(seed)
	local cells = GameConstants.FLOOR_GRID_CELLS
	local cellSize = GameConstants.FLOOR_CELL_SIZE_STUDS
	local side = cells * cellSize

	local model = Instance.new("Model")
	model.Name = "GreyboxFloor"

	local function cellCenter(cx: number, cz: number): Vector3
		return origin + Vector3.new((cx - 0.5) * cellSize, 0, (cz - 0.5) * cellSize)
	end

	-- Floor plate + perimeter walls.
	local center = origin + Vector3.new(side / 2, 0, side / 2)
	makePart(
		model,
		"Plate",
		Vector3.new(side, 1, side),
		CFrame.new(center - Vector3.new(0, 0.5, 0)),
		Color3.fromRGB(96, 96, 102)
	)
	local wallColor = Color3.fromRGB(72, 72, 80)
	local wallHeight = 14
	makePart(
		model,
		"WallN",
		Vector3.new(side + 4, wallHeight, 2),
		CFrame.new(center + Vector3.new(0, wallHeight / 2, -side / 2 - 1)),
		wallColor
	)
	makePart(
		model,
		"WallS",
		Vector3.new(side + 4, wallHeight, 2),
		CFrame.new(center + Vector3.new(0, wallHeight / 2, side / 2 + 1)),
		wallColor
	)
	makePart(
		model,
		"WallW",
		Vector3.new(2, wallHeight, side + 4),
		CFrame.new(center + Vector3.new(-side / 2 - 1, wallHeight / 2, 0)),
		wallColor
	)
	makePart(
		model,
		"WallE",
		Vector3.new(2, wallHeight, side + 4),
		CFrame.new(center + Vector3.new(side / 2 + 1, wallHeight / 2, 0)),
		wallColor
	)

	-- Crew spawns at the loading dock end of the factory; cases get richer deeper in.
	local spawnCell = Vector2.new(1, 1)
	local dockCell = Vector2.new(2, 1)

	-- Interior obstacle walls (skip the spawn/dock cells so the dock area stays open).
	for cx = 1, cells do
		for cz = 1, cells do
			local isSpawn = cx == spawnCell.X and cz == spawnCell.Y
			local isDock = cx == dockCell.X and cz == dockCell.Y
			if not isSpawn and not isDock and rng:NextNumber() < 0.45 then
				local rotated = rng:NextNumber() < 0.5
				local size = if rotated
					then Vector3.new(2, 10, cellSize * 0.55)
					else Vector3.new(cellSize * 0.55, 10, 2)
				makePart(
					model,
					"Obstacle",
					size,
					CFrame.new(cellCenter(cx, cz) + Vector3.new(0, 5, 0)),
					Color3.fromRGB(84, 84, 92)
				)
			end
		end
	end

	-- Spawn pad (tagged for teleports).
	local spawnPad = makePart(
		model,
		"ShiftSpawn",
		Vector3.new(10, 0.6, 10),
		CFrame.new(cellCenter(spawnCell.X, spawnCell.Y) + Vector3.new(0, 0.3, 0)),
		Color3.fromRGB(80, 140, 200)
	)
	CollectionService:AddTag(spawnPad, TAG_FLOOR_SPAWN)

	-- Extraction dock (tagged trigger pad + marker pillars).
	local dockCenter = cellCenter(dockCell.X, dockCell.Y)
	local dockPad = makePart(
		model,
		"ExtractionDock",
		Vector3.new(14, 0.6, 14),
		CFrame.new(dockCenter + Vector3.new(0, 0.3, 0)),
		Color3.fromRGB(235, 190, 52)
	)
	CollectionService:AddTag(dockPad, TAG_EXTRACTION_DOCK)
	makePart(
		model,
		"DockPillar",
		Vector3.new(1.5, 10, 1.5),
		CFrame.new(dockCenter + Vector3.new(-7, 5, -7)),
		Color3.fromRGB(235, 190, 52)
	)
	makePart(
		model,
		"DockPillar",
		Vector3.new(1.5, 10, 1.5),
		CFrame.new(dockCenter + Vector3.new(7, 5, 7)),
		Color3.fromRGB(235, 190, 52)
	)

	-- Case anchors: 1-2 per non-spawn cell, tier scaling with distance from the
	-- dock (guarantees Tier1 anchors within 2 cells of the dock — §G time-to-first-case).
	for cx = 1, cells do
		for cz = 1, cells do
			if cx == spawnCell.X and cz == spawnCell.Y then
				continue
			end
			for _ = 1, rng:NextInteger(1, 2) do
				local ox = rng:NextNumber(0.18, 0.4) * cellSize * (if rng:NextNumber() < 0.5 then -1 else 1)
				local oz = rng:NextNumber(0.18, 0.4) * cellSize * (if rng:NextNumber() < 0.5 then -1 else 1)
				local anchor = Instance.new("Part")
				anchor.Name = "CaseAnchor"
				anchor.Size = Vector3.new(1, 1, 1)
				anchor.CFrame = CFrame.new(cellCenter(cx, cz) + Vector3.new(ox, 1, oz))
				anchor.Anchored = true
				anchor.CanCollide = false
				anchor.Transparency = 1
				local distance = math.max(math.abs(cx - dockCell.X), math.abs(cz - dockCell.Y))
				local tier: number
				if distance <= 1 then
					tier = 1
				elseif distance <= 3 then
					tier = if rng:NextNumber() < 0.65 then 1 else 2
				else
					local roll = rng:NextNumber()
					tier = if roll < 0.25 then 1 elseif roll < 0.7 then 2 else 3
				end
				anchor:SetAttribute("CaseTier", tier)
				CollectionService:AddTag(anchor, TAG_CASE_ANCHOR)
				anchor.Parent = model
			end
		end
	end

	model.Parent = parent
	return model
end

--------------------------------------------------------------------------------
-- Floor generation (FloorGenService if present, else the fallback above),
-- normalized to ShiftSession's FloorLike contract
--------------------------------------------------------------------------------

local function getShiftContainer(): Folder
	local existing = Workspace:FindFirstChild("NightShiftFloor")
	if existing ~= nil and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = "NightShiftFloor"
	folder.Parent = Workspace
	return folder
end

local function findFirstTaggedIn(root: Instance, tag: string): BasePart?
	for _, instance in CollectionService:GetTagged(tag) do
		if instance:IsA("BasePart") and instance:IsDescendantOf(root) then
			return instance
		end
	end
	return nil
end

local function resolveSpawnCFrame(
	floorRoot: Instance,
	dockSpawns: { BasePart },
	override: CFrame?,
	origin: Vector3
): CFrame
	if override ~= nil then
		return override
	end
	if #dockSpawns > 0 then
		return dockSpawns[1].CFrame + Vector3.new(0, 4, 0)
	end
	local spawnPart = findFirstTaggedIn(floorRoot, TAG_FLOOR_SPAWN)
	if spawnPart ~= nil then
		return spawnPart.CFrame + Vector3.new(0, 4, 0)
	end
	return CFrame.new(origin + Vector3.new(18, 5, 18))
end

local function collectDockSpawns(candidates: any): { BasePart }
	local dockSpawns: { BasePart } = {}
	if type(candidates) == "table" then
		for _, pad in candidates :: { any } do
			if typeof(pad) == "Instance" and pad:IsA("BasePart") then
				table.insert(dockSpawns, pad)
			end
		end
	end
	return dockSpawns
end

-- Per-session generation options forwarded to FloorGenService.Generate
-- (WP1.5 GenerateOptions): the slot origin, the session id stamped as the
-- model's SessionId attribute (WP4.3 dock->session resolution keys off it),
-- and the live-session light-density gate (Change 6.9).
type FloorOpts = {
	origin: Vector3,
	sessionId: string,
	lightDensityScale: number,
}

-- One floor per session, at the session's slot origin. Preference order
-- (WP6.1: the pre-handle legacy-shape wrapping — and with it the only
-- consumers of FloorGen's retired single-floor shims — is gone;
-- FloorGenService has returned FloorHandles exclusively since WP1.5):
--   1) FloorGenService's R2 FloorHandle (WP1.5) — model/spawn/docks/Destroy
--      (flicker teardown lives in the handle; SessionId stamped by FloorGen).
--   2) The local greybox fallback floor, built at the slot origin (SessionId
--      stamped here so floor->session resolution works on both shapes).
local function generateFloor(seed: number, floorOpts: FloorOpts): FloorLike
	local floorGen = getSibling("FloorGenService")
	if floorGen ~= nil and type(floorGen.Generate) == "function" then
		local ok, result = pcall(floorGen.Generate, seed, floorOpts)
		if not ok then
			warn(`[ShiftService] FloorGenService.Generate failed (using fallback floor): {result}`)
		elseif
			type(result) == "table"
			and typeof(result.model) == "Instance"
			and type(result.Destroy) == "function"
		then
			-- R2 FloorHandle.
			local handle = result
			local dockSpawns = collectDockSpawns(handle.dockSpawns)
			local override = if typeof(handle.spawnCFrame) == "CFrame" then handle.spawnCFrame :: CFrame else nil
			return {
				model = handle.model :: Instance,
				spawnCFrame = resolveSpawnCFrame(handle.model, dockSpawns, override, floorOpts.origin),
				dockSpawns = dockSpawns,
				Destroy = function(_self: FloorLike)
					pcall(function()
						handle:Destroy()
					end)
				end,
			}
		else
			warn("[ShiftService] FloorGenService.Generate returned a non-handle shape (using fallback floor)")
		end
	end

	local container = getShiftContainer()
	local model = buildFallbackFloor(seed, container, floorOpts.origin)
	model:SetAttribute("SessionId", floorOpts.sessionId)
	return {
		model = model,
		spawnCFrame = resolveSpawnCFrame(model, {}, nil, floorOpts.origin),
		dockSpawns = {},
		Destroy = function(_self: FloorLike)
			pcall(function()
				model:Destroy()
			end)
		end,
	}
end

--------------------------------------------------------------------------------
-- Downed / revive facade (the records live on each session; routing is
-- playerToSession ONLY — a player with no session can never be downed)
--------------------------------------------------------------------------------

function ShiftService.IsDowned(player: Player): boolean
	local session = playerToSession[player]
	return session ~= nil and session:IsDowned(player)
end

function ShiftService.DownPlayer(player: Player)
	local session = playerToSession[player]
	if session ~= nil then
		session:DownPlayer(player)
	end
end

function ShiftService.RevivePlayer(player: Player): boolean
	local session = playerToSession[player]
	if session == nil then
		return false
	end
	return session:RevivePlayer(player)
end

-- RequestReviveTeammate (contract B): argument/target validation here, the
-- server-timed hold runs on the TARGET's session (records + busy guard there).
local function onRequestRevive(player: Player, targetUserId: any): { [string]: any }
	if type(targetUserId) ~= "number" then
		return { ok = false, err = "BAD_ARG" }
	end
	local target = Players:GetPlayerByUserId(targetUserId)
	if target == nil or target == player then
		return { ok = false, err = "BAD_TARGET" }
	end
	local session = playerToSession[target]
	if session == nil then
		return { ok = false, err = "NOT_DOWNED" }
	end
	return session:RunReviveHold(player, target)
end

--------------------------------------------------------------------------------
-- Death routing (real deaths scatter carried cases at the body — handled by
-- the player's session; hub deaths just clean up carried cases)
--------------------------------------------------------------------------------

local function onDeath(player: Player, character: Model)
	local session = playerToSession[player]
	if session ~= nil then
		session:HandleDeath(player, character)
		-- An un-extracted run death drops the player from the roster; clear the
		-- routing index with it (extracted players keep their mapping until the
		-- session tears down — they are still that shift's alumni).
		if not session:IsParticipant(player) then
			playerToSession[player] = nil
		end
		return
	end
	local caseService = getSibling("CaseService")
	if caseService ~= nil and type(caseService.LoseCarried) == "function" then
		caseService.LoseCarried(player) -- outside a shift, carried cases just clean up
	end
end

--------------------------------------------------------------------------------
-- Fix #4 — server-authoritative respawn with a skippable timer.
-- Engine default respawn is OFF (Players.CharacterAutoLoads = false, set in
-- Init); the server now owns the post-death wait via a task.delay that calls
-- player:LoadCharacter(). A RemoteEvent ("RespawnTimer") tells the client the
-- deadline so it can render an accurate countdown + a "RESPAWN NOW" button that
-- routes back to ShiftService.RespawnNow (RemoteFunction "RequestRespawnNow"),
-- which short-circuits the wait. Spam-safe: skip is rejected with
-- NO_PENDING_RESPAWN when no timer is pending (cannot force-reload a character
-- or dupe out of the downed window).
--------------------------------------------------------------------------------

local RESPAWN_WAIT_SECONDS = 5 -- matches the old engine RespawnTime default

local respawnAt: { [Player]: number } = {}
local respawnPending: { [Player]: thread } = {}

local respawnTimerRemote: RemoteEvent? = nil

-- Load a fresh character (pcall-fenced, guarded by player.Parent). Clears the
-- pending state first so the loaded character's CharacterAdded -> Died can arm a
-- new timer cleanly.
local function doRespawn(player: Player)
	respawnAt[player] = nil
	respawnPending[player] = nil
	if player.Parent ~= Players then
		return
	end
	local ok, err = pcall(function()
		player:LoadCharacter()
	end)
	if not ok then
		warn(`[ShiftService] LoadCharacter failed for {player.Name}: {err}`)
	end
end

-- Arm the skippable post-death timer. Idempotent: a timer already pending is
-- left in place (never stacked), so a second Died (or a re-entrant call) cannot
-- create a second LoadCharacter.
local function startRespawnTimer(player: Player)
	if respawnPending[player] ~= nil then
		return
	end
	local endsAt = Workspace:GetServerTimeNow() + RESPAWN_WAIT_SECONDS
	respawnAt[player] = endsAt
	respawnPending[player] = task.delay(RESPAWN_WAIT_SECONDS, function()
		-- The thread that fires owns the respawn; clear our handle first so the
		-- guard in RespawnNow/doRespawn sees no pending timer.
		respawnPending[player] = nil
		doRespawn(player)
	end)
	if respawnTimerRemote ~= nil then
		respawnTimerRemote:FireClient(player, { endsAt = endsAt })
	end
end

-- Clear any pending respawn for a player (leave / teardown).
local function clearRespawnState(player: Player)
	local pending = respawnPending[player]
	if pending ~= nil then
		task.cancel(pending)
	end
	respawnPending[player] = nil
	respawnAt[player] = nil
end

-- RemoteFunction entrypoint: skip the post-death wait. Rejects when no timer is
-- pending (anti-exploit: cannot be spammed to force a reload or dupe out of the
-- downed/bleedout window).
function ShiftService.RespawnNow(player: Player): { [string]: any }
	if respawnPending[player] == nil then
		return { ok = false, err = "NO_PENDING_RESPAWN" }
	end
	task.cancel(respawnPending[player])
	respawnPending[player] = nil
	respawnAt[player] = nil
	doRespawn(player)
	return { ok = true }
end

--------------------------------------------------------------------------------
-- Speed validation — ONE global loop for every live session (Change 6.6: the
-- dispatcher scales sessions, never validator loops). The client sets
-- WalkSpeed locally for sprint; the server validates ACTUAL horizontal
-- velocity against the uncarried sprint cap (carry slowdown only ever reduces
-- speed, so the bare SPRINT_SPEED cap is the correct upper bound).
--------------------------------------------------------------------------------

local SPEED_CAP_STUDS_PER_SECOND = GameConstants.SPRINT_SPEED * 1.35 -- physics slack
local SPEED_STRIKES_BEFORE_SNAPBACK = 3 -- consecutive 1s ticks over the cap
-- Teleport detection slack on top of cap*elapsed (covers physics jitter and a
-- lag-spiked tick); any single-tick horizontal displacement beyond it is a
-- CFrame teleport (exploiters set CFrame directly, which leaves
-- AssemblyLinearVelocity untouched — the velocity check alone never sees it).
local TELEPORT_SLACK_STUDS = 12
local VALIDATOR_TICK_SECONDS = 1

local speedStrikes: { [Player]: number } = {}
local lastValidPosition: { [Player]: Vector3 } = {}
local lastSeenPosition: { [Player]: Vector3 } = {}
local lastSeenClock: { [Player]: number } = {}

local function clearValidatorState(player: Player)
	speedStrikes[player] = nil
	lastValidPosition[player] = nil
	lastSeenPosition[player] = nil
	lastSeenClock[player] = nil
end

local function validateParticipantSpeeds()
	for player, session in playerToSession do
		if session.state ~= "Active" then
			continue
		end
		if not session:IsParticipant(player) or session:HasExtracted(player) or session:IsDowned(player) then
			continue
		end
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root == nil or not root:IsA("BasePart") then
			continue
		end

		-- Teleport sanity check (extraction integrity): validate ACTUAL
		-- displacement since the last tick, not just reported velocity. Vertical
		-- movement (falls) is ignored; only horizontal travel is capped.
		local clock = os.clock()
		local position = root.Position
		local previousPosition = lastSeenPosition[player]
		local previousClock = lastSeenClock[player]
		lastSeenPosition[player] = position
		lastSeenClock[player] = clock
		if previousPosition ~= nil and previousClock ~= nil then
			local elapsed = math.max(clock - previousClock, 1 / 60)
			local offset = position - previousPosition
			local horizontalDelta = Vector3.new(offset.X, 0, offset.Z).Magnitude
			if horizontalDelta > SPEED_CAP_STUDS_PER_SECOND * elapsed + TELEPORT_SLACK_STUDS then
				local snapback = lastValidPosition[player] or previousPosition
				character:PivotTo(CFrame.new(snapback))
				lastSeenPosition[player] = snapback
				warn(
					`[ShiftService] {player.Name} moved {math.floor(horizontalDelta)} studs in {string.format(
						"%.2f",
						elapsed
					)}s (teleport?) — snapped back`
				)
				track(player, "teleport_violation", { studs = math.floor(horizontalDelta) })
				continue
			end
		end

		local velocity = root.AssemblyLinearVelocity
		local horizontalSpeed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
		if horizontalSpeed > SPEED_CAP_STUDS_PER_SECOND then
			local strikes = (speedStrikes[player] or 0) + 1
			speedStrikes[player] = strikes
			if strikes >= SPEED_STRIKES_BEFORE_SNAPBACK then
				speedStrikes[player] = 0
				local snapback = lastValidPosition[player]
				if snapback ~= nil and character ~= nil then
					character:PivotTo(CFrame.new(snapback))
					lastSeenPosition[player] = snapback -- keep the teleport check coherent
				end
				warn(
					`[ShiftService] {player.Name} sustained {math.floor(horizontalSpeed)} studs/s (cap {math.floor(
						SPEED_CAP_STUDS_PER_SECOND
					)}) — snapped back`
				)
				track(player, "speed_violation", { speed = math.floor(horizontalSpeed) })
			end
		else
			speedStrikes[player] = 0
			lastValidPosition[player] = root.Position
		end
	end
end

-- Server-initiated teleport (e.g. ConsumableService's EXIT_WARP warp to the
-- extraction dock): re-seed the movement validator at the player's new position
-- so the legitimate jump is not snapped back as an exploit on the next tick.
-- Callers invoke this immediately (no yield) after moving the character.
function ShiftService.NoteServerTeleport(player: Player)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root ~= nil and root:IsA("BasePart") then
		lastSeenPosition[player] = root.Position
		lastSeenClock[player] = os.clock()
		lastValidPosition[player] = root.Position
		speedStrikes[player] = 0
	end
end

--------------------------------------------------------------------------------
-- Shift lifecycle facade (global calls aggregate; per-player calls route)
--------------------------------------------------------------------------------

function ShiftService.GetState(): string
	local aggregate = "Intermission"
	for _, session in sessions do
		if session.state == "Active" then
			return "Active"
		end
		if session.state == "Complete" then
			aggregate = "Complete"
		end
	end
	return aggregate
end

function ShiftService.IsActive(): boolean
	for _, session in sessions do
		if session.state == "Active" then
			return true
		end
	end
	return false
end

-- Single-session compat reads (the one live session this wave). Per-player
-- consumers should prefer the *For variants below.
function ShiftService.GetShiftId(): string?
	local session = anySession()
	return if session ~= nil then session.id else nil
end

function ShiftService.GetFloorRoot(): Instance?
	local session = anySession()
	return if session ~= nil then session:GetFloorRoot() else nil
end

function ShiftService.IsParticipant(player: Player): boolean
	local session = playerToSession[player]
	return session ~= nil and session:IsParticipant(player)
end

function ShiftService.HasExtracted(player: Player): boolean
	local session = playerToSession[player]
	return session ~= nil and session:HasExtracted(player)
end

-- ExtractionService calls this once the dock dwell completes. Extracted players
-- wait out the shift at the hub (greybox spectate).
function ShiftService.MarkExtracted(player: Player)
	local session = playerToSession[player]
	if session ~= nil then
		session:MarkExtracted(player)
	else
		ShiftService.ReturnToHub(player) -- legacy semantics: the return always happens
	end
end

-- R2 additive session API (Change 6.2.2).
function ShiftService.GetSessionOf(player: Player): Session?
	return playerToSession[player]
end

function ShiftService.GetFloorRootFor(player: Player): Instance?
	local session = playerToSession[player]
	return if session ~= nil then session:GetFloorRoot() else nil
end

function ShiftService.GetShiftIdFor(player: Player): string?
	local session = playerToSession[player]
	return if session ~= nil then session.id else nil
end

-- Real 5-slot pool count (WP5.2). The pad plans its T=0 bins against this and
-- marks overflow bins "ALL FLOORS RUNNING" (deferred, never dropped); the
-- start-now vote requires a free slot server-side.
function ShiftService.GetFreeSlotCount(): number
	local free = 0
	for slot = 1, DISPATCH.SLOT_COUNT do
		if slotBusy[slot] ~= true then
			free += 1
		end
	end
	return free
end

-- Contract I: 2x shift pay with PASS_2X_PAY, safe pcall-require defaulting 1x.
function ShiftService.GetPayMultiplier(player: Player): number
	local monetization = getSibling("MonetizationService")
	if monetization ~= nil and type(monetization.OwnsPass) == "function" then
		local ok, owns = pcall(monetization.OwnsPass, player, "PASS_2X_PAY")
		if ok and owns == true then
			return 2
		end
	end
	return 1
end

-- Nightly seed (RotationService if present, else the unix day) mixed with a
-- counter that increments strictly per-SESSION (never per cycle — Change
-- 6.8), so back-to-back shifts AND two same-cycle bins always get distinct
-- floors.
-- Per-server salt so two servers (or the same place restarted) never replay
-- the same floor sequence — every game that starts rolls its own layouts.
-- The nightly seed stays in the mix so the wall's rotation timer still marks
-- a real global reshuffle of the layout pool.
local serverSeedSalt = Random.new():NextInteger(0, 2 ^ 30)

local function computeSeed(): number
	local baseSeed: number? = nil
	local rotation = getSibling("RotationService")
	if rotation ~= nil and type(rotation.GetNightlySeed) == "function" then
		local ok, result = pcall(rotation.GetNightlySeed)
		if ok and type(result) == "number" then
			baseSeed = result
		end
	end
	if baseSeed == nil then
		baseSeed = math.floor(os.time() / GameConstants.SECONDS_PER_DAY)
	end
	return (math.floor(baseSeed :: number) * 73856093 + shiftCounter * 19349663 + serverSeedSalt * 83492791)
		% 2147483647
end

-- Is this player standing in the hub's CLOCK IN zone? Exact zone test via
-- HubService (Stage 2); falls back to the spawn-radius heuristic only when
-- HubService or its zone is absent (greybox fallback pad), so players idling
-- at spawn / the unbox stage no longer auto-queue.
local function isInQueueZone(player: Player, root: BasePart): boolean
	local hub = getSibling("HubService")
	if hub ~= nil and type(hub.IsInClockInZone) == "function" and type(hub.GetClockInZone) == "function" then
		local okZone, zone = pcall(hub.GetClockInZone)
		if okZone and zone ~= nil then
			local ok, inside = pcall(hub.IsInClockInZone, player)
			return ok and inside == true
		end
	end
	return (root.Position - hubSpawnPosition).Magnitude <= INTERMISSION_ZONE_RADIUS_STUDS
end

-- Everyone who voted RequeueShift, plus everyone standing in the hub's CLOCK IN
-- zone. One dispatch per cycle this wave, so a squad that re-queues together
-- lands on the same floor together (§3.2 co-play hook).
local function collectQueuedPlayers(): { Player }
	local queued: { Player } = {}
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if character == nil or humanoid == nil or humanoid.Health <= 0 then
			continue
		end
		local include = requeueVotes[player] == true
		if not include and root ~= nil and root:IsA("BasePart") then
			include = isInQueueZone(player, root)
		end
		if include then
			table.insert(queued, player)
		end
	end
	return queued
end

local function runIntermission()
	intermissionEndsAt = os.time() + GameConstants.INTERMISSION_SECONDS
	broadcastState()
	task.wait(GameConstants.INTERMISSION_SECONDS)
end

--------------------------------------------------------------------------------
-- WP5.2 — metronome pad integration (Change 6.1). QueuePadService/DispatchCore
-- own every timing rule (perpetual 45 s epoch, T-3 freeze, T=0 snapshot,
-- party-aware FIFO bins); ShiftService only consumes the pending bins and
-- launches one session per bin.
--------------------------------------------------------------------------------

-- The pad drives dispatch only while it is actually LIVE: module present with
-- the dispatch API, and its zone mirror publishing (the pad stamps a
-- QueueState attribute on the clock-in zone when it activates; a degraded pad
-- never does — its GetPendingDispatch stays nil forever and would stall
-- shifts).
local function getActiveQueuePad(): any
	local queuePad = getSibling("QueuePadService")
	if
		queuePad == nil
		or type(queuePad.GetPendingDispatch) ~= "function"
		or type(queuePad.ConsumeDispatch) ~= "function"
		or type(queuePad.AddRequeueVote) ~= "function"
	then
		return nil
	end
	local hub = getSibling("HubService")
	if hub == nil or type(hub.GetClockInZone) ~= "function" then
		return nil
	end
	local ok, zone = pcall(hub.GetClockInZone)
	if not ok or typeof(zone) ~= "Instance" then
		return nil
	end
	if zone:GetAttribute("QueueState") == nil then
		return nil
	end
	return queuePad
end

-- A pad bin re-intersected with players still in the server and alive at
-- teleport time (same liveness test as collectQueuedPlayers), plus the
-- security §5.2 backstop: a player already routed to a live session (incl.
-- extracted alumni whose mapping persists until teardown) can never occupy a
-- second one — the pad excludes them too (GetSessionOf ~= nil); this is
-- defense in depth.
local function filterAlive(players: { Player }): { Player }
	local alive: { Player } = {}
	for _, player in players do
		if typeof(player) ~= "Instance" or not player:IsA("Player") or player.Parent ~= Players then
			continue
		end
		if playerToSession[player] ~= nil then
			continue
		end
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if character ~= nil and humanoid ~= nil and humanoid.Health > 0 then
			table.insert(alive, player)
		end
	end
	return alive
end

-- Pad-driven wait: poll GetPendingDispatch (0.25 s) until the metronome
-- reaches T=0 with >= 1 bin (or a unanimous start-now vote produces an extra
-- bin — the epoch is never touched either way), acknowledge with
-- ConsumeDispatch, and return the raw FIFO bins. Nil = pad degraded mid-wait;
-- the legacy fixed countdown takes over.
local function runPadDispatchWait(queuePad: any): { { Player } }?
	-- The pad's ShiftEpoch/CountdownEndsAt attributes are the live timer on
	-- this path: no deadline in ShiftState (RunHUD "--:--"; the pad
	-- billboard/UI count down locally).
	intermissionEndsAt = nil
	broadcastState()

	while true do
		if getActiveQueuePad() == nil then
			return nil -- pad degraded mid-wait; legacy countdown takes over
		end
		local okPending, pending = pcall(queuePad.GetPendingDispatch)
		if not okPending then
			return nil
		end
		if pending ~= nil then
			local okConsume, bins = pcall(queuePad.ConsumeDispatch)
			if not okConsume or type(bins) ~= "table" then
				return nil
			end
			return bins :: { { Player } }
		end
		task.wait(PAD_DISPATCH_POLL_SECONDS)
	end
end

--------------------------------------------------------------------------------
-- In-shift AFK watchdog (Change 6.1.6 — WP5.2): one bounded sampler per
-- session, stopped through the session janitor. Two rules, both from
-- LobbyConfig.DISPATCH:
--   (a) first-window idler: < INSHIFT_AFK_MOVE_STUDS (10) of path moved AND 0
--       crates within the first INSHIFT_AFK_WINDOW (60 s) -> auto-recall to
--       the hub + a strike report to QueuePadService.ReportAfkStrike (2
--       strikes -> PAD_COOLDOWN_SECONDS lockout, owned by the pad). "0
--       crates": nothing banked (extracted players are exempt by definition —
--       they already left the floor) and nothing carried (a pickup is proof
--       of activity).
--   (b) whole-group inactive GROUP_IDLE_TEARDOWN_SECONDS (90 s) -> early
--       session:Destroy() (protects Best Employees + the part budget from
--       parked groups).
--------------------------------------------------------------------------------

local function getCarriedCount(player: Player): number
	local caseService = getSibling("CaseService")
	if caseService ~= nil and type(caseService.GetCarriedCount) == "function" then
		local ok, count = pcall(caseService.GetCarriedCount, player)
		if ok and type(count) == "number" then
			return count
		end
	end
	return 0
end

-- Auto-recall: the idler leaves the roster exactly like a leaver (downed
-- cleanup + the empty-roster early end both come for free), lands back at the
-- hub (ReturnToHub re-seeds the movement validator), and the strike lands on
-- the pad's cooldown ledger. pcall-fenced: a missing/old pad never blocks the
-- recall itself.
local function recallAfkPlayer(session: Session, player: Player)
	session:RemovePlayer(player)
	if playerToSession[player] == session then
		playerToSession[player] = nil
		clearValidatorState(player)
	end
	if player.Parent == Players then
		ShiftService.ReturnToHub(player)
		sendStateTo(player) -- participant=false: reopen the storefront immediately
	end
	track(player, "afk_recall", { sessionId = session.id })
	local queuePad = getSibling("QueuePadService")
	if queuePad ~= nil and type(queuePad.ReportAfkStrike) == "function" then
		pcall(queuePad.ReportAfkStrike, player)
	end
end

local function startInShiftAfkWatchdog(session: Session)
	local stopped = false
	table.insert(session.janitor, function()
		stopped = true
	end)

	task.spawn(function()
		local activeSince: number? = nil
		local pathMoved: { [Player]: number } = {}
		local lastPosition: { [Player]: Vector3 } = {}
		local lastActiveAt: { [Player]: number } = {}
		local firstWindowChecked = false

		while not stopped and sessions[session.id] == session do
			if session.state == "Active" then
				local now = os.clock()
				if activeSince == nil then
					activeSince = now
				end

				local consideredCount = 0
				local idleCount = 0
				for player in session.participants do
					if session:HasExtracted(player) then
						continue -- banked + back at the hub; never AFK-judged
					end
					local character = player.Character
					local root = character and character:FindFirstChild("HumanoidRootPart")
					if root == nil or not root:IsA("BasePart") then
						continue
					end
					consideredCount += 1
					local position = root.Position
					local previous = lastPosition[player]
					lastPosition[player] = position
					if previous == nil then
						pathMoved[player] = 0
						lastActiveAt[player] = now
						continue
					end
					local delta = (position - previous).Magnitude
					pathMoved[player] = (pathMoved[player] or 0) + delta
					-- A downed player is the Defect's doing, not AFK: bleedout
					-- pins the root, so stillness while downed counts as active.
					if delta > AFK_ACTIVITY_EPSILON_STUDS or session:IsDowned(player) then
						lastActiveAt[player] = now
					end
					if now - (lastActiveAt[player] or now) >= DISPATCH.GROUP_IDLE_TEARDOWN_SECONDS then
						idleCount += 1
					end
				end

				-- (a) One-shot first-window check at the first tick past 60 s.
				if not firstWindowChecked and now - (activeSince :: number) >= DISPATCH.INSHIFT_AFK_WINDOW then
					firstWindowChecked = true
					local recall: { Player } = {}
					for player in session.participants do
						if session:HasExtracted(player) or session:IsDowned(player) then
							continue
						end
						local moved = pathMoved[player]
						if
							moved ~= nil
							and moved < DISPATCH.INSHIFT_AFK_MOVE_STUDS
							and getCarriedCount(player) == 0
						then
							table.insert(recall, player)
						end
					end
					for _, player in recall do
						recallAfkPlayer(session, player)
					end
				end

				-- (b) Whole group parked for 90 s -> early teardown. Destroy is
				-- idempotent and routes stragglers home; the Run thread's
				-- watchdog then falls through harmlessly.
				if consideredCount > 0 and idleCount == consideredCount then
					warn(`[ShiftService] session {session.id}: whole group inactive — early teardown`)
					session:Destroy()
					break
				end
			end
			task.wait(AFK_WATCHDOG_TICK_SECONDS)
		end
	end)
end

--------------------------------------------------------------------------------
-- Session dispatch (Change 6.2.3 — WP5.2): one ShiftSession per consumed pad
-- bin, each at its own slot origin; same-tick bins launch in one loop
-- iteration with no waits between them.
--------------------------------------------------------------------------------

local function bindPlayer(player: Player, session: Session)
	playerToSession[player] = session
end

local function onSessionDestroyed(session: Session)
	sessions[session.id] = nil
	for player, owned in playerToSession do
		if owned == session then
			playerToSession[player] = nil
			clearValidatorState(player)
		end
	end
	-- Slot release ordering (Change 6.2.3 — the WP5.2 manual review point):
	-- onDestroyed is the FINAL step of ShiftSession:Destroy(), sequenced after
	-- _teardownFloor() destroyed the floor model — so the origin is freed only
	-- once the dying floor is gone and can never be re-issued underneath it.
	-- The crash path (Run's pcall) routes through the same Destroy, so a
	-- crashed session never blocks the dispatcher or leaks its slot.
	releaseSlot(session.slot)
end

local sessionDeps: ShiftSession.SessionDeps = {
	getSibling = getSibling,
	returnToHub = function(player: Player)
		ShiftService.ReturnToHub(player)
	end,
	noteServerTeleport = function(player: Player)
		ShiftService.NoteServerTeleport(player)
	end,
	broadcastState = broadcastState,
	sendStateTo = sendStateTo,
	fireDownedState = fireDownedStateFor,
	bindPlayer = bindPlayer,
	onDestroyed = onSessionDestroyed,
}

local function countSessions(): number
	local count = 0
	for _ in sessions do
		count += 1
	end
	return count
end

-- One bin -> one session at the slot's origin. The seed counter increments
-- per SESSION (never per cycle — Change 6.8) so two same-tick bins always get
-- distinct floors.
local function buildSession(roster: { Player }, slot: number, liveSessionCount: number): Session
	shiftCounter += 1
	local seed = computeSeed()
	local id = HttpService:GenerateGUID(false)
	local floorHandle = generateFloor(seed, {
		origin = slotOrigin(slot),
		sessionId = id,
		-- Change 6.9 / R6 Fix #1: floor-internal light density scales down as
		-- live sessions stack, but FloorLightPlan now CLAMPS it to a >=50%
		-- overhead-lit floor (effFrac = clamp(0.72*scale, 0.50, 0.72)) and
		-- fills every other room with an orange/purple night-light, so floors
		-- are never "too dark" under load yet still never quintuple the load.
		lightDensityScale = 1 / math.max(liveSessionCount, 1),
	})
	return ShiftSession.new({
		id = id,
		slot = slot,
		seed = seed,
		roster = roster,
		floorHandle = floorHandle,
		deps = sessionDeps,
	})
end

-- Change 6.7 streaming hygiene: when StreamingEnabled is on, pre-pull the
-- slot origin for every dispatched player (bounded; best-effort) before the
-- session's own thread pivots them 2000+ studs; PivotTo (never
-- TeleportService) and the validator re-seed stay inside ShiftSession._start
-- via deps.noteServerTeleport. When streaming is off, nothing changes and the
-- launch stays same-tick.
local function runSession(session: Session, roster: { Player })
	if Workspace.StreamingEnabled then
		task.spawn(function()
			local spawnPosition = session.floorHandle.spawnCFrame.Position
			for _, player in roster do
				pcall(function()
					player:RequestStreamAroundAsync(spawnPosition, STREAM_PULL_TIMEOUT_SECONDS)
				end)
			end
			session:Run()
		end)
	else
		session:Run()
	end
end

-- Acquire a slot, build, register, run. Returns false when the bin defers
-- (pool exhausted) or construction failed — in both cases the players stay in
-- the lobby and ride the next cycle; the slot is reclaimed on the failure
-- path because no session was ever registered to release it.
local function dispatchBin(roster: { Player }, liveSessionCount: number): boolean
	local slot = acquireSlot()
	if slot == nil then
		return false -- all floors running; this bin alone defers
	end
	local ok, sessionOrErr = pcall(buildSession, roster, slot, liveSessionCount)
	if not ok then
		releaseSlot(slot)
		warn(`[ShiftService] session construction failed (slot {slot} reclaimed): {sessionOrErr}`)
		return false
	end
	local session = sessionOrErr :: Session
	sessions[session.id] = session
	startInShiftAfkWatchdog(session)
	runSession(session, roster)
	return true
end

-- Consume ALL of one pad dispatch in a single tick: 6 occupants -> [4][2] ->
-- two floors at distinct origins the same tick (no waits between bins, no
-- group ever held back).
local function dispatchBins(bins: { { Player } })
	local rosters: { { Player } } = {}
	for _, bin in bins do
		if type(bin) ~= "table" then
			continue
		end
		local roster = filterAlive(bin)
		-- Defensive cap (security §5.2): bins arrive <= DISPATCH.BIN_SIZE (4)
		-- by DispatchCore construction; enforce it here regardless of pad
		-- traffic.
		while #roster > DISPATCH.BIN_SIZE do
			table.remove(roster)
		end
		if #roster > 0 then
			table.insert(rosters, roster)
		end
	end
	if #rosters == 0 then
		return
	end

	-- Light-density gate input (Change 6.9): every floor launching this
	-- consume counts as live — both same-tick bins generate against the same
	-- target count.
	local liveSessionCount = countSessions() + #rosters
	for _, roster in rosters do
		dispatchBin(roster, liveSessionCount)
	end
	table.clear(requeueVotes) -- votes consumed by this dispatch
end

-- Legacy no-pad fallback dispatch (kept for test places — fixed 45 s
-- intermission + collectQueuedPlayers -> ONE session): same pool, slot-1-first
-- by construction, and the old single-session pacing — wait for THIS session
-- to tear down (onSessionDestroyed clears it, including on the crash path)
-- before the next intermission.
local function dispatchLegacySession(queued: { Player })
	local slot = acquireSlot()
	if slot == nil then
		return -- defensive: the sequential wait below never leaves one live here
	end
	local ok, sessionOrErr = pcall(buildSession, queued, slot, countSessions() + 1)
	if not ok then
		releaseSlot(slot)
		warn(`[ShiftService] session construction failed (slot {slot} reclaimed): {sessionOrErr}`)
		return
	end
	local session = sessionOrErr :: Session
	sessions[session.id] = session
	table.clear(requeueVotes) -- votes consumed by this dispatch
	startInShiftAfkWatchdog(session)
	runSession(session, queued)

	while sessions[session.id] ~= nil do
		task.wait(SESSION_WAIT_POLL_SECONDS)
	end
end

--------------------------------------------------------------------------------
-- Player wiring
--------------------------------------------------------------------------------

local lastRequeueForwardAt: { [Player]: number } = {}

local function onRequeue(player: Player, _payload: any)
	-- WP4.1: with the pad live, the squad re-queue vote lands in its queue
	-- (roster or FIFO overflow — §3.2 co-play). AddRequeueVote is idempotent
	-- and a Queue.Leave can cancel it, so the vote stays re-castable — no
	-- hard dedupe, just a 1 s cooldown bounding remote spam.
	local queuePad = getActiveQueuePad()
	if queuePad ~= nil then
		local clock = os.clock()
		local last = lastRequeueForwardAt[player]
		if last ~= nil and clock - last < REQUEUE_FORWARD_COOLDOWN_SECONDS then
			return
		end
		lastRequeueForwardAt[player] = clock
		pcall(queuePad.AddRequeueVote, player)
		if not requeueVotes[player] then
			requeueVotes[player] = true -- keeps the legacy collector coherent if the pad degrades + dedupes analytics
			track(player, "requeue")
		end
		return
	end
	if requeueVotes[player] then
		return
	end
	requeueVotes[player] = true
	track(player, "requeue")
end

local function onCharacterAdded(player: Player, character: Model)
	local humanoid = character:WaitForChild("Humanoid", 10)
	if humanoid == nil or not humanoid:IsA("Humanoid") then
		return
	end
	-- Fix #5: every (re)spawn starts at full base health, deterministically.
	-- Pet maxHealth perk re-applies on top via its PetHealthApplied attribute
	-- (0 on a fresh Humanoid), so this is the BASE only and the perk stacks fine.
	-- Both MaxHealth and Health must be written for the reset to be reliable.
	humanoid.MaxHealth = 100
	humanoid.Health = 100
	humanoid.WalkSpeed = GameConstants.WALKSPEED_BASE
	-- Kill the default "Health" regen script (1% MaxHealth/s): it out-heals the
	-- Defect's >=6s post-attack cadence and breaks the two-hit-kill contract
	-- (DefectService §G). Healing is consumables-only.
	task.spawn(function()
		local healthScript = character:WaitForChild("Health", 10)
		if healthScript ~= nil and healthScript:IsA("BaseScript") then
			healthScript.Disabled = true
		end
	end)
	humanoid.Died:Connect(function()
		onDeath(player, character)
		-- Fix #4: with CharacterAutoLoads off, the server owns respawn. Arm the
		-- skippable post-death timer (the client gets the deadline and a
		-- "RESPAWN NOW" button via RespawnTimer / RequestRespawnNow).
		startRespawnTimer(player)
	end)
end

local function onPlayerAdded(player: Player)
	player.CharacterAdded:Connect(function(character)
		task.spawn(onCharacterAdded, player, character)
	end)
	local character = player.Character
	if character ~= nil then
		task.spawn(onCharacterAdded, player, character)
	end
	-- Late joiners get the current shift state immediately (per-player payload
	-- so the participant flag is always present).
	sendStateTo(player)
	-- Fix #4 MANDATORY corollary: CharacterAutoLoads is OFF, so the engine no
	-- longer spawns the first character. Load it once here (pcall-fenced) if the
	-- player has none — omitting this ships characterless joiners.
	if player.Character == nil then
		pcall(function()
			player:LoadCharacter()
		end)
	end
end

local function onPlayerRemoving(player: Player)
	-- Leave routing is playerToSession ONLY (Change 6.2): the session drops the
	-- leaver from its roster (an empty roster ends the session early).
	local session = playerToSession[player]
	if session ~= nil then
		playerToSession[player] = nil
		session:RemovePlayer(player)
	end
	requeueVotes[player] = nil
	lastRequeueForwardAt[player] = nil
	clearValidatorState(player)
	-- Fix #4: cancel + clear any pending respawn for the leaver.
	clearRespawnState(player)
end

--------------------------------------------------------------------------------
-- Loader lifecycle
--------------------------------------------------------------------------------

function ShiftService:Init()
	-- Fix #4: the server takes ownership of respawn. With auto-load off the
	-- engine never reloads a dead/joining character — onPlayerAdded loads the
	-- first one and the Died-armed timer (or RespawnNow) loads every subsequent.
	Players.CharacterAutoLoads = false

	-- Remotes exist already (init.server calls Remotes.InitServer before Init).
	local ok, err = pcall(function()
		shiftStateRemote = Remotes.GetEvent("ShiftState")
		downedStateRemote = Remotes.GetEvent("PlayerDownedState")
		respawnTimerRemote = Remotes.GetEvent("RespawnTimer")
		Remotes.GetEvent("RequeueShift").OnServerEvent:Connect(onRequeue)
		Remotes.GetFunction("RequestReviveTeammate").OnServerInvoke = function(player: Player, targetUserId: any)
			return onRequestRevive(player, targetUserId)
		end
		-- Fix #4: skip-the-wait entrypoint (rejects NO_PENDING_RESPAWN when idle).
		Remotes.GetFunction("RequestRespawnNow").OnServerInvoke = function(player: Player)
			return ShiftService.RespawnNow(player)
		end
	end)
	if not ok then
		warn(`[ShiftService] remote bind failed: {err}`)
	end

	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
end

function ShiftService:Start()
	ensureHubSpawn()

	-- ONE global speed/teleport validator for every live session (Change 6.6):
	-- iterates playerToSession so N concurrent sessions never spawn N validator
	-- loops. Per-player validator state clears on leave and on session teardown.
	task.spawn(function()
		while true do
			validateParticipantSpeeds()
			task.wait(VALIDATOR_TICK_SECONDS)
		end
	end)

	-- The perpetual dispatcher. WP5.2: a live QueuePadService owns the 45 s
	-- metronome (perpetual epoch — empty T=0s roll over silently on the pad
	-- side; nothing stalls here) and this loop just consumes its pending
	-- dispatches — N concurrent sessions run free, so the loop NEVER blocks on
	-- teardown. The legacy fixed countdown + clock-in-zone collector is the
	-- fallback whenever the pad is absent or degraded — re-checked every
	-- cycle; empty servers never burn part budget generating floors (§3.2
	-- join gate).
	while true do
		local queuePad = getActiveQueuePad()
		if queuePad ~= nil then
			local bins = runPadDispatchWait(queuePad)
			if bins ~= nil then
				dispatchBins(bins)
			end
			-- nil = pad degraded mid-wait; re-check hands over to the legacy path
		else
			runIntermission()
			local queued = collectQueuedPlayers()
			if #queued > 0 then
				dispatchLegacySession(queued)
			end
		end
	end
end

return ShiftService
