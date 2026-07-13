--!strict
-- CRYPTLINGS: NIGHT SHIFT — LobbyPlotService (lobby SOP §3.2-§3.4; LOBBY_BUILD_PLAN
-- WP2.6). Owns which player lives on which of the 20 street lots.
--
-- Single source of truth = the server-side PlotAssign core state, keyed by
-- Player INSTANCE (never UserId — instance identity survives nothing a stale
-- lookup could fake). The per-plot Workspace.Lobby.Plots models carry a
-- replicated ATTRIBUTE MIRROR for client UI only (PlotIndex / OwnerUserId /
-- OwnerName / HouseTier) — attributes are never decision data.
--
-- Race discipline (SOP §3.2 — release is written FIRST in this file):
--   * PlayerRemoving clears the truth table + attributes synchronously, THEN
--     fires OccupantChanged; game:BindToClose backstops shutdown.
--   * A periodic sweep treats "owner not in Players:GetPlayers()" as
--     releasable (PlayerRemoving is not guaranteed on hard disconnects).
--     Liveness NEVER goes through a UserId lookup — stale window under
--     deferred events.
--   * Assign is ONE function (join signal + startup sweep), and the find and
--     the mark live in PlotAssign.assign — zero yields between them, so the
--     Grow-a-Garden double-claim race cannot exist.
--   * Every profile-load / streaming yield in the spawn flow re-checks
--     player.Parent ~= Players and releases on failure.
--
-- Spawn flow (SOP §3.4): only the FIRST CharacterAdded of a session is ever
-- pivoted — returning players (profile.stats.firstShiftDone) stream their lot
-- in and land on the sidewalk in front of it, facing the Factory; fresh
-- profiles stay at the plaza SpawnLocation beside the queue pad. Mid-session
-- respawns and shift returns are never touched.
--
-- Public API:
--   LobbyPlotService.GetPlotForPlayer(player) -> { index, stationCFrame, model }?
--   LobbyPlotService.GetPlotByIndex(index) -> { index, stationCFrame, model }?
--   LobbyPlotService.GetOccupancy() -> { [plotIndex]: Player }
--   LobbyPlotService.OccupantChanged:Connect(fn(index, player?)) -> connection

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConstants = require(Shared:WaitForChild("Config"):WaitForChild("GameConstants"))
local LobbyConfig = require(Shared:WaitForChild("Config"):WaitForChild("LobbyConfig"))
local PlotAssign = require(Shared:WaitForChild("Logic"):WaitForChild("PlotAssign"))

--------------------------------------------------------------------------------
-- Tuning
--------------------------------------------------------------------------------

local TAG_PLOT = "Plot"

local SWEEP_SECONDS = 5 -- ghost-owner sweep cadence (hard-disconnect backstop)
local PROFILE_WAIT_SECONDS = 15 -- bounded wait for the profile on first spawn;
-- past it we degrade to first-join behavior (plaza spawn), never block
local PROFILE_POLL_SECONDS = 0.25
local SPAWN_LIFT_STUDS = 3 -- pivot height above the sidewalk surface

-- Lot center -> sidewalk centerline along the station's LookVector (the lot
-- anchor looks at the street — StreetBuilder/HubService contract).
local SIDEWALK_OFFSET_STUDS = LobbyConfig.LOT_DEPTH_STUDS / 2 + LobbyConfig.SIDEWALK_WIDTH_STUDS / 2

-- Street axis = X with the Factory at the east end (LOBBY_BUILD_PLAN Wave-2
-- invariant; ShiftService's on-shift heuristic depends on it too).
local FACTORY_DIRECTION = Vector3.xAxis

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

export type PlotInfo = {
	index: number,
	stationCFrame: CFrame,
	model: Model,
}

export type OccupantListener = (index: number, player: Player?) -> ()
export type OccupantConnection = { Disconnect: (self: OccupantConnection) -> () }

local LobbyPlotService = {}

local active = false
local assignState: PlotAssign.State = PlotAssign.new(0)
local plots: { [number]: PlotInfo } = {}

local spawnHandled: { [Player]: boolean } = {} -- first-CharacterAdded-of-session latch
local characterConns: { [Player]: RBXScriptConnection } = {}

--------------------------------------------------------------------------------
-- Lazy sibling resolution (house pattern: a missing parallel-stage module
-- degrades that feature, never plot bookkeeping)
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

-- PlayerDataService with the surface the spawn flow relies on, or nil.
local function getDataService(): any
	local dataService = getSibling("PlayerDataService")
	if dataService ~= nil and type(dataService.Get) == "function" and type(dataService.IsLoaded) == "function" then
		return dataService
	end
	return nil
end

--------------------------------------------------------------------------------
-- OccupantChanged signal (lightweight; listeners run spawned so a slow or
-- broken consumer can never stall the release path)
--------------------------------------------------------------------------------

local occupantListeners: { OccupantListener } = {}

local OccupantChanged = {}

function OccupantChanged.Connect(_self: any, listener: OccupantListener): OccupantConnection
	assert(type(listener) == "function", "OccupantChanged:Connect expects a function")
	table.insert(occupantListeners, listener)
	local connection = {}
	function connection.Disconnect(_conn: any)
		local found = table.find(occupantListeners, listener)
		if found ~= nil then
			table.remove(occupantListeners, found)
		end
	end
	return (connection :: any) :: OccupantConnection
end

LobbyPlotService.OccupantChanged = table.freeze(OccupantChanged)

local function fireOccupantChanged(index: number, player: Player?)
	for _, listener in table.clone(occupantListeners) do
		task.spawn(listener, index, player)
	end
end

--------------------------------------------------------------------------------
-- Attribute mirror helpers (display data only — truth lives in assignState)
--------------------------------------------------------------------------------

local function mirrorVacant(plot: PlotInfo)
	plot.model:SetAttribute("OwnerUserId", 0)
	plot.model:SetAttribute("OwnerName", "")
	plot.model:SetAttribute("HouseTier", 0)
end

local function mirrorOwner(plot: PlotInfo, player: Player)
	plot.model:SetAttribute("OwnerUserId", player.UserId)
	plot.model:SetAttribute("OwnerName", player.DisplayName)
end

--------------------------------------------------------------------------------
-- Release — written FIRST (SOP §3.2: release-on-leave is the most commonly
-- forgotten step). Synchronous: truth table, then attrs, then signal.
--------------------------------------------------------------------------------

local function releasePlot(player: Player)
	local conn = characterConns[player]
	if conn ~= nil then
		conn:Disconnect()
		characterConns[player] = nil
	end
	spawnHandled[player] = nil

	local index = PlotAssign.release(assignState, player)
	if index == nil then
		return -- owned no plot (release/sweep overlap is a harmless no-op)
	end
	local plot = plots[index]
	if plot ~= nil then
		mirrorVacant(plot)
		pcall(function()
			plot.model:RemovePersistentPlayer(player)
		end)
	end
	fireOccupantChanged(index, nil)
end

-- Hard-disconnect backstop: anything owning a plot that is not in the live
-- player list is a ghost. Owners are snapshotted first so per-player session
-- state can be cleaned for keys PlayerRemoving never saw.
local function sweepGhosts()
	local ownersBefore: { [number]: Player } = {}
	for index = 1, assignState.plotCount do
		local owner = PlotAssign.ownerOf(assignState, index)
		if owner ~= nil then
			ownersBefore[index] = owner :: Player
		end
	end

	local released = PlotAssign.sweep(assignState, Players:GetPlayers())
	for _, index in released do
		local ghost = ownersBefore[index]
		if ghost ~= nil then
			local conn = characterConns[ghost]
			if conn ~= nil then
				conn:Disconnect()
				characterConns[ghost] = nil
			end
			spawnHandled[ghost] = nil
		end
		local plot = plots[index]
		if plot ~= nil then
			mirrorVacant(plot)
			if ghost ~= nil then
				-- Pairing discipline (Security Review Scope §4): every
				-- AddPersistentPlayer is matched on the sweep path too, so a
				-- hard-disconnected ghost never leaves a stale persistence
				-- entry on the plot model.
				pcall(function()
					plot.model:RemovePersistentPlayer(ghost)
				end)
			end
		end
		fireOccupantChanged(index, nil)
	end
end

--------------------------------------------------------------------------------
-- Spawn flow (SOP §3.4) — runs spawned off the first CharacterAdded of the
-- session; every yield is followed by a liveness re-check.
--------------------------------------------------------------------------------

local function sidewalkSpawnCFrame(stationCFrame: CFrame): CFrame
	local position = stationCFrame.Position
		+ stationCFrame.LookVector * SIDEWALK_OFFSET_STUDS
		+ Vector3.new(0, SPAWN_LIFT_STUDS, 0)
	return CFrame.lookAt(position, position + FACTORY_DIRECTION)
end

local function handleFirstSpawn(player: Player, character: Model)
	if spawnHandled[player] then
		return -- mid-session respawn / shift return: never pivot (SOP §3.4)
	end
	spawnHandled[player] = true

	local dataService = getDataService()
	if dataService == nil then
		return -- degrade to first-join behavior: plaza SpawnLocation
	end

	-- Bounded wait for the profile; unloaded past the deadline = first-join
	-- behavior (the plaza spawn is always correct for a fresh profile).
	local deadline = os.clock() + PROFILE_WAIT_SECONDS
	while not dataService.IsLoaded(player) do
		if os.clock() >= deadline then
			return
		end
		task.wait(PROFILE_POLL_SECONDS)
		if player.Parent ~= Players then
			releasePlot(player) -- left during the profile-load yield
			return
		end
	end
	if player.Parent ~= Players then
		releasePlot(player)
		return
	end

	local profile = dataService.Get(player)
	if profile == nil then
		return
	end

	local index = PlotAssign.indexOf(assignState, player)
	local plot = if index ~= nil then plots[index] else nil
	if plot == nil then
		return
	end

	-- Mirror the now-known housing tier (display only; ShelfRoomBuilder owns
	-- the structural rebuild).
	local housing = profile.housing
	if type(housing) == "table" and type(housing.tier) == "number" then
		plot.model:SetAttribute("HouseTier", housing.tier)
	end

	local stats = profile.stats
	if type(stats) ~= "table" or stats.firstShiftDone ~= true then
		return -- fresh profile: stay at the plaza SpawnLocation beside the pad
	end

	-- Returning player: stream the lot in, then pivot to the sidewalk in
	-- front of it, facing the Factory.
	local spawnCFrame = sidewalkSpawnCFrame(plot.stationCFrame)
	pcall(function()
		player:RequestStreamAroundAsync(spawnCFrame.Position)
	end)
	task.wait(0.1) -- defensive against fall-through (SOP §3.4)
	if player.Parent ~= Players then
		releasePlot(player)
		return
	end
	if player.Character ~= character or character.Parent == nil then
		return -- respawned/despawned during the streaming yield
	end
	character:PivotTo(spawnCFrame)
end

--------------------------------------------------------------------------------
-- Assign — ONE function for the join signal AND the startup sweep. The find
-- and the mark are a single synchronous PlotAssign.assign call (no yields).
--------------------------------------------------------------------------------

local function assignPlot(player: Player)
	if not active then
		return
	end

	local index = PlotAssign.assign(assignState, player)
	if index == nil then
		-- Unreachable in production: MaxPlayers 20 == 20 lots. Warn only.
		warn(`[LobbyPlotService] no vacant plot for {player.Name} — street full`)
		return
	end
	local plot = plots[index]
	if plot == nil then
		return
	end

	mirrorOwner(plot, player)
	pcall(function()
		-- PersistentPerPlayer model: the owner's own lot never streams out
		-- for them; paired with RemovePersistentPlayer in releasePlot.
		plot.model:AddPersistentPlayer(player)
	end)
	fireOccupantChanged(index, player)

	-- Spawn flow: only the first CharacterAdded of the session is handled
	-- (assign is idempotent, so guard against double-wiring too).
	if characterConns[player] == nil then
		characterConns[player] = player.CharacterAdded:Connect(function(character)
			task.spawn(handleFirstSpawn, player, character)
		end)
		local existing = player.Character
		if existing ~= nil then
			task.spawn(handleFirstSpawn, player, existing)
		end
	end
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

function LobbyPlotService.GetPlotForPlayer(player: Player): PlotInfo?
	local index = PlotAssign.indexOf(assignState, player)
	if index == nil then
		return nil
	end
	return plots[index]
end

function LobbyPlotService.GetPlotByIndex(index: number): PlotInfo?
	return plots[index]
end

-- Snapshot of plot index -> owning Player (occupied plots only).
function LobbyPlotService.GetOccupancy(): { [number]: Player }
	local occupancy: { [number]: Player } = {}
	for index = 1, assignState.plotCount do
		local owner = PlotAssign.ownerOf(assignState, index)
		if owner ~= nil then
			occupancy[index] = owner :: Player
		end
	end
	return occupancy
end

--------------------------------------------------------------------------------
-- Loader lifecycle
--------------------------------------------------------------------------------

function LobbyPlotService:Init()
	if active then
		return
	end

	-- Lot anchors from HubService (alphabetical Init order H < L guarantees
	-- the street geometry already exists). Missing/empty = degraded boot:
	-- every API stays safe and returns nil/empty.
	local hub = getSibling("HubService")
	if hub == nil or type(hub.GetDisplayStationSlots) ~= "function" then
		warn("[LobbyPlotService] HubService unavailable — plot system disabled")
		return
	end
	local ok, slots = pcall(hub.GetDisplayStationSlots)
	if not ok or type(slots) ~= "table" or #slots == 0 then
		warn("[LobbyPlotService] no display station slots — plot system disabled")
		return
	end
	if #slots ~= GameConstants.HUB_DISPLAY_STATION_COUNT then
		warn(`[LobbyPlotService] {#slots} lot anchors (spec {GameConstants.HUB_DISPLAY_STATION_COUNT})`)
	end

	assignState = PlotAssign.new(#slots)

	-- Workspace.Lobby.Plots mirror (SOP §3.1): one Model per plot around an
	-- invisible anchored Origin part at the lot's stationCFrame.
	local lobbyFolder = Workspace:FindFirstChild("Lobby")
	if lobbyFolder == nil or not lobbyFolder:IsA("Folder") then
		lobbyFolder = Instance.new("Folder")
		lobbyFolder.Name = "Lobby"
		lobbyFolder.Parent = Workspace
	end
	local plotsFolder = Instance.new("Folder")
	plotsFolder.Name = "Plots"

	for _, slot in slots do
		local index = slot.index :: number
		local stationCFrame = slot.stationCFrame :: CFrame

		local model = Instance.new("Model")
		model.Name = string.format("Plot%02d", index)
		-- PersistentPerPlayer behaves as Atomic (§3.1) for everyone except
		-- the players added via AddPersistentPlayer — which pins the owner's
		-- own lot into their stream (§3.4).
		model.ModelStreamingMode = Enum.ModelStreamingMode.PersistentPerPlayer

		local origin = Instance.new("Part")
		origin.Name = "Origin"
		origin.Anchored = true
		origin.Size = Vector3.one
		origin.CFrame = stationCFrame
		origin.Transparency = 1
		origin.CanCollide = false
		origin.CanTouch = false
		origin.CanQuery = false
		origin.CastShadow = false
		origin.Parent = model
		model.PrimaryPart = origin

		model:SetAttribute("PlotIndex", index)
		CollectionService:AddTag(model, TAG_PLOT)
		model.Parent = plotsFolder

		local plot: PlotInfo = table.freeze({
			index = index,
			stationCFrame = stationCFrame,
			model = model,
		})
		plots[index] = plot
		mirrorVacant(plot)
	end

	plotsFolder.Parent = lobbyFolder
	active = true

	-- Release wiring FIRST (SOP §3.2), then shutdown backstop, then assign.
	Players.PlayerRemoving:Connect(releasePlot)
	game:BindToClose(function()
		for _, player in Players:GetPlayers() do
			releasePlot(player)
		end
	end)
	Players.PlayerAdded:Connect(assignPlot)
end

function LobbyPlotService:Start()
	if not active then
		return
	end

	-- Startup sweep: players who joined before our connections existed
	-- (missed-join race) go through the same single assign function.
	for _, player in Players:GetPlayers() do
		assignPlot(player)
	end

	-- Periodic ghost sweep — PlayerRemoving is not guaranteed on hard
	-- disconnects; "owner not in Players" is the only liveness test used.
	while true do
		task.wait(SWEEP_SECONDS)
		sweepGhosts()
	end
end

return LobbyPlotService
