--!strict
-- CRYPTLINGS: NIGHT SHIFT — HubService (street-lobby orchestrator, WP3.1 rewrite).
-- Thin orchestrator over the LobbyBuild builder modules: every Part of the
-- night-street lobby is constructed by the Wave-2 builders; HubService only
-- sequences them, captures their returned fixtures, enforces the SOP §10
-- budgets, and re-exposes the preserved public API every consumer
-- (ShiftService, TradeService, SessionStatsService, ShelfRoomBuilder,
-- UnboxService, the countdown / onboarding / shop clients) already depends on.
--
-- Build order (Init, LOBBY_SOP §12): LobbyLighting.Apply() -> StreetBuilder ->
-- FactoryBuilder -> QueuePadBuilder -> WallBuilder -> ShopBuilder ->
-- PlazaBuilder -> ComingSoonBuilder -> DecorBuilder, all parented under one
-- Workspace Model named "NightShiftHub" (name preserved — CountdownUI,
-- OnboardingController, and ShiftService fallbacks key off it) at
-- GameConstants.HUB_ORIGIN (-2000, 0, 0). Street axis = X, Factory east.
--
-- Streaming (SOP §10): Factory / BrainrotWall / ShopBuilding landmark Models
-- are Persistent (players orient by them); every other child Model is Atomic.
--
-- Start() owns the three lobby loops: the TOP COLLECTORS leaderboard refresh,
-- the ON SHIFT NOW roster sign, and the Coming-Soon marquee flicker
-- (random 3-8 s, Neon <-> SmoothPlastic for 0.1 s — SOP §9).
--
-- Deliberately deleted from the old hub (plan WP3.1): title gantry, rainbow
-- chase strip, bobbing orbs, spinning case, and the server-built "CURRENT
-- PETS" ledge wall (replaced by the Brainrot wall + client BrainrotWallUI).
--
-- Public API (unchanged contract, byte-compatible signatures):
--   HubService.GetSpawn() -> SpawnLocation?
--   HubService.GetSpawnPosition() -> Vector3        -- consumed by ShiftService
--   HubService.GetUnboxStage() -> Model?            -- children: UnboxPedestal, ConfettiAnchor, StageSpotlight
--   HubService.GetClockInZone() -> BasePart?        -- the queue pad zone volume
--   HubService.IsInClockInZone(player) -> boolean   -- delegates to QueuePadService.IsOnPad when present
--   HubService.GetCountdownWall() -> BasePart?
--   HubService.GetDisplayStationSlots() -> { { index: number, stationCFrame: CFrame } }
--   HubService.GetOddsBoard() -> BasePart?          -- nil (odds live in the theater popup)
--   HubService.GetShopKiosk() -> BasePart?
--   HubService.GetTradePads() -> { BasePart }
--   HubService.GetLockerBank() -> { BasePart }   -- always {} (Addendum 1 Change 4: lockers are UI-tab-only)
--   HubService.GetLockerForPlayer(player) -> BasePart?  -- always nil (Change 4)
--   HubService.GetHubModel() -> Model?
--
-- R2 additive fixtures (Addendum 1 / build plan WP2.3):
--   HubService.GetQueuePadBuild() -> QueuePadBuilder.QueuePadBuild?  -- full builder return (QueuePadService prefers it)
--   HubService.GetBestEmployeesBoard() -> { board: BasePart, cards: { BestEmployeesCard } }?  -- SessionStatsService renders the cards
--   HubService.GetSwapMeetBeacon() -> BasePart?  -- the tagged Neon head; TradeService stamps TradeActive on it
--   HubService.GetLotFixtures() -> { StreetBuilder.LotFixture }  -- per-lot wash/trim/beacon/nameplate (LotStatusController joins by PlotIndex)

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConstants = require(Shared:WaitForChild("Config"):WaitForChild("GameConstants"))
local LobbyConfig = require(Shared:WaitForChild("Config"):WaitForChild("LobbyConfig"))
local RarityTable = require(Shared:WaitForChild("Config"):WaitForChild("RarityTable"))

local LobbyBuild = script.Parent:WaitForChild("LobbyBuild")
local ComingSoonBuilder = require(LobbyBuild:WaitForChild("ComingSoonBuilder"))
local DecorBuilder = require(LobbyBuild:WaitForChild("DecorBuilder"))
local FactoryBuilder = require(LobbyBuild:WaitForChild("FactoryBuilder"))
local LobbyLighting = require(LobbyBuild:WaitForChild("LobbyLighting"))
local PartKit = require(LobbyBuild:WaitForChild("PartKit"))
local PlazaBuilder = require(LobbyBuild:WaitForChild("PlazaBuilder"))
local QueuePadBuilder = require(LobbyBuild:WaitForChild("QueuePadBuilder"))
local ShopBuilder = require(LobbyBuild:WaitForChild("ShopBuilder"))
local StreetBuilder = require(LobbyBuild:WaitForChild("StreetBuilder"))
local WallBuilder = require(LobbyBuild:WaitForChild("WallBuilder"))

--------------------------------------------------------------------------------
-- Tuning — gameplay counts come from GameConstants/LobbyConfig; geometry
-- numbers live inside the builders.
--------------------------------------------------------------------------------

local HUB_ORIGIN = Vector3.new(GameConstants.HUB_ORIGIN.X, GameConstants.HUB_ORIGIN.Y, GameConstants.HUB_ORIGIN.Z)
local HUB_PART_BUDGET = GameConstants.PART_BUDGET_HUB
local LIGHT_BUDGET = LobbyConfig.LIGHT_BUDGET
local LOT_COUNT = GameConstants.HUB_DISPLAY_STATION_COUNT -- 20 lots, always

-- Landmark Models that must never stream out (SOP §10: Persistent sparingly —
-- exactly the three buildings players orient by). Everything else is Atomic.
local PERSISTENT_LANDMARKS: { [string]: boolean } = {
	Factory = true,
	BrainrotWall = true,
	ShopBuilding = true,
}

-- "On a shift" heuristic for the status sign: character further than this
-- from the hub origin is out on a shift floor (preserved from the old hub).
local ON_SHIFT_DISTANCE_STUDS = 400
local STATUS_SIGN_REFRESH_SECONDS = 3

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

-- Per-lot anchor: lot center on the pad top, LookVector toward the street —
-- the exact shape ShelfRoomBuilder consumes via GetDisplayStationSlots().
export type DisplayStationSlot = { index: number, stationCFrame: CFrame }
-- Back-compat alias (older annotations referenced ShelfDoorSlot).
export type ShelfDoorSlot = DisplayStationSlot

local HubService = {}

-- Best Employees board fixture (Addendum 1 Change 2): the board part plus the
-- 4 portrait cards QueuePadBuilder ships EMPTY; SessionStatsService renders.
export type BestEmployeesBoardFixture = {
	board: BasePart,
	cards: { QueuePadBuilder.BestEmployeesCard },
}

local hubModel: Model? = nil
local spawnLocation: SpawnLocation? = nil
local unboxStage: Model? = nil
local clockInZone: BasePart? = nil
local countdownWall: BasePart? = nil
local oddsBoard: BasePart? = nil
local tradePads: { BasePart } = {}
local stationSlots: { DisplayStationSlot } = {}
local shopKiosk: BasePart? = nil
local factorySignLabel: TextLabel? = nil
local leaderboardRows: { TextLabel } = {}
local flickerParts: { BasePart } = {}
local queuePadBuild: QueuePadBuilder.QueuePadBuild? = nil
local bestEmployeesBoard: BestEmployeesBoardFixture? = nil
local swapMeetBeaconHead: BasePart? = nil
local lotFixtures: { StreetBuilder.LotFixture } = {}

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

--------------------------------------------------------------------------------
-- Leaderboard refresh (factory billboard rows; value-ranked, §1.1)
--------------------------------------------------------------------------------

local function collectionPoints(collection: { [string]: number }): number
	local total = 0
	for id, count in collection do
		if type(count) == "number" and count > 0 then
			local def = RarityTable.GetCryptling(id)
			local rarity = if type(def) == "table" then def.rarity else nil
			local points = if rarity ~= nil then (GameConstants.LEADERBOARD_POINTS :: any)[rarity] else nil
			total += (if type(points) == "number" then points else 0) * count
		end
	end
	return total
end

local function refreshLeaderboard()
	if #leaderboardRows == 0 then
		return
	end
	local dataService = getSibling("PlayerDataService")

	local entries: { { name: string, points: number } } = {}
	for _, player in Players:GetPlayers() do
		local points = 0
		if
			dataService ~= nil
			and type(dataService.Get) == "function"
			and type(dataService.IsLoaded) == "function"
			and dataService.IsLoaded(player)
		then
			local data = dataService.Get(player)
			if data ~= nil and type(data.collection) == "table" then
				points = collectionPoints(data.collection)
			end
		end
		table.insert(entries, { name = player.DisplayName, points = points })
	end
	table.sort(entries, function(a, b)
		return a.points > b.points
	end)

	for index, row in leaderboardRows do
		local entry = entries[index]
		row.Text = if entry ~= nil then string.format("%d.  %s — %d", index, entry.name, entry.points) else ""
	end
end

--------------------------------------------------------------------------------
-- "On shift now" status sign refresh
--------------------------------------------------------------------------------

local function refreshFactorySign()
	local label = factorySignLabel
	if label == nil then
		return
	end
	-- "In the factory" = character is far from the hub (out on a shift floor).
	local names: { string } = {}
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if
			root ~= nil
			and root:IsA("BasePart")
			and (root.Position - HUB_ORIGIN).Magnitude > ON_SHIFT_DISTANCE_STUDS
		then
			table.insert(names, player.DisplayName)
		end
	end
	if #names == 0 then
		label.Text = "Nobody on shift right now"
		label.TextColor3 = Color3.fromRGB(150, 150, 150)
	else
		label.Text = table.concat(names, "\n")
		label.TextColor3 = Color3.fromRGB(120, 230, 150)
	end
end

--------------------------------------------------------------------------------
-- Coming-Soon marquee flicker (SOP §9: random 3-8 s interval, the Neon letter
-- parts blink to SmoothPlastic for 0.1 s — the derelict-signage tic)
--------------------------------------------------------------------------------

local flickerRng = Random.new()

local function flickerOnce()
	if #flickerParts == 0 then
		return
	end
	for _, part in flickerParts do
		part.Material = Enum.Material.SmoothPlastic
	end
	task.wait(LobbyConfig.COMING_SOON_FLICKER.BLINK_SECONDS)
	for _, part in flickerParts do
		part.Material = Enum.Material.Neon
	end
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

function HubService.GetHubModel(): Model?
	return hubModel
end

function HubService.GetSpawn(): SpawnLocation?
	return spawnLocation
end

-- Stage 1 hook: ShiftService.ensureHubSpawn() pcalls this for the hub position.
function HubService.GetSpawnPosition(): Vector3
	local pad = spawnLocation
	if pad ~= nil then
		return pad.Position + Vector3.new(0, 2.5, 0)
	end
	-- FactoryBuilder's plaza spawn slot (façade x=365 minus 27, beside the pad).
	return HUB_ORIGIN + Vector3.new(338, 3, -24)
end

function HubService.GetUnboxStage(): Model?
	return unboxStage
end

function HubService.GetClockInZone(): BasePart?
	return clockInZone
end

-- Queue membership: QueuePadService's zone-volume roster is authoritative when
-- present; otherwise fall back to the old XZ-footprint test on the zone part
-- (test places without the queue service keep working).
function HubService.IsInClockInZone(player: Player): boolean
	local queuePadService = getSibling("QueuePadService")
	if queuePadService ~= nil and type(queuePadService.IsOnPad) == "function" then
		local ok, onPad = pcall(queuePadService.IsOnPad, player)
		if ok then
			return onPad == true
		end
	end
	local zone = clockInZone
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if zone == nil or root == nil or not root:IsA("BasePart") then
		return false
	end
	local offset = root.Position - zone.Position
	return math.abs(offset.X) <= zone.Size.X / 2
		and math.abs(offset.Z) <= zone.Size.Z / 2
		and offset.Y >= -2
		and offset.Y <= 10
end

function HubService.GetCountdownWall(): BasePart?
	return countdownWall
end

function HubService.GetOddsBoard(): BasePart?
	return oddsBoard
end

function HubService.GetShopKiosk(): BasePart?
	return shopKiosk
end

function HubService.GetDisplayStationSlots(): { DisplayStationSlot }
	return stationSlots
end

-- Back-compat alias: ShelfRoomBuilder historically asked for "shelf door slots".
function HubService.GetShelfDoorSlots(): { DisplayStationSlot }
	return stationSlots
end

function HubService.GetTradePads(): { BasePart }
	return tradePads
end

-- Physical lockers were removed in Addendum 1 Change 4 (locker is UI-tab-only).
-- Both getters keep byte-compatible signatures for legacy consumers: the bank
-- is always empty and no player ever has a world locker.
function HubService.GetLockerBank(): { BasePart }
	return {}
end

function HubService.GetLockerForPlayer(_player: Player): BasePart?
	return nil
end

-- Full QueuePadBuilder return table (QueuePadService prefers this over the
-- name-scan fallback).
function HubService.GetQueuePadBuild(): QueuePadBuilder.QueuePadBuild?
	return queuePadBuild
end

-- Best Employees board + cards (Addendum 1 Change 2); SessionStatsService
-- renders the top-4 crate collectors into the cards.
function HubService.GetBestEmployeesBoard(): BestEmployeesBoardFixture?
	return bestEmployeesBoard
end

-- The swap-meet beacon's Neon head (Addendum 1 Change 5, tagged
-- "SwapMeetBeacon"); TradeService stamps the TradeActive attribute on it.
function HubService.GetSwapMeetBeacon(): BasePart?
	return swapMeetBeaconHead
end

-- Per-lot claim fixtures (Addendum 1 Change 1), indexed like the station
-- slots; LotStatusController joins them to plot models by PlotIndex.
function HubService.GetLotFixtures(): { StreetBuilder.LotFixture }
	return lotFixtures
end

--------------------------------------------------------------------------------
-- Loader lifecycle
--------------------------------------------------------------------------------

function HubService:Init()
	if hubModel ~= nil then
		return
	end

	-- Global night pass first (SOP §2): Lighting/Atmosphere/Sky/post FX are
	-- single-owner here; FloorGenService delegates to the same module.
	LobbyLighting.Apply()

	local model = Instance.new("Model")
	model.Name = "NightShiftHub"

	local street = StreetBuilder.Build(model, HUB_ORIGIN)
	local factory = FactoryBuilder.Build(model, HUB_ORIGIN)
	local queuePad = QueuePadBuilder.Build(model, HUB_ORIGIN)
	WallBuilder.Build(model, HUB_ORIGIN)
	local shop = ShopBuilder.Build(model, HUB_ORIGIN)
	local plaza = PlazaBuilder.Build(model, HUB_ORIGIN)
	local comingSoon = ComingSoonBuilder.Build(model, HUB_ORIGIN)
	DecorBuilder.Build(model, HUB_ORIGIN)

	-- Capture the preserved-contract fixtures (the locker bank is gone —
	-- Addendum 1 Change 4 removed the physical lockers from FactoryBuilder).
	stationSlots = street.slots
	assert(#stationSlots == LOT_COUNT, "[HubService] lot count drifted from spec")
	lotFixtures = street.lotFixtures
	spawnLocation = factory.spawnLocation
	countdownWall = factory.countdownWall
	factorySignLabel = factory.statusLabel
	leaderboardRows = factory.leaderboardRows
	clockInZone = queuePad.zonePart
	queuePadBuild = queuePad
	bestEmployeesBoard = { board = queuePad.bestEmployeesBoard, cards = queuePad.bestEmployeesCards }
	shopKiosk = shop.counter
	unboxStage = plaza.unboxStage
	tradePads = plaza.tradePads
	swapMeetBeaconHead = plaza.swapBeaconHead
	flickerParts = comingSoon.flickerParts

	-- Streaming modes (SOP §10): the three landmarks persist, the rest is
	-- Atomic so distant chunks stream in/out whole.
	for _, child in model:GetChildren() do
		if child:IsA("Model") then
			child.ModelStreamingMode = if PERSISTENT_LANDMARKS[child.Name] == true
				then Enum.ModelStreamingMode.Persistent
				else Enum.ModelStreamingMode.Atomic
		end
	end

	model.Parent = Workspace
	hubModel = model
	model.PrimaryPart = spawnLocation

	-- SOP §10 budget guards: street + landmarks part cap and the global
	-- streamed-in light cap (every PartKit light self-registers).
	local partCount = PartKit.CountParts(model)
	if partCount > HUB_PART_BUDGET then
		warn(`[HubService] hub uses {partCount} parts — over the {HUB_PART_BUDGET} budget`)
	end
	local lightCount = PartKit.LightBudget.Count()
	if lightCount > LIGHT_BUDGET then
		warn(`[HubService] lobby registers {lightCount} lights — over the {LIGHT_BUDGET} budget`)
	end
end

function HubService:Start()
	-- Leaderboard billboard refresh (hub-only geometry by construction).
	task.spawn(function()
		while true do
			refreshLeaderboard()
			task.wait(GameConstants.LEADERBOARD_REFRESH_SECONDS)
		end
	end)

	-- "On shift now" board: refresh the roster every ~3s.
	task.spawn(function()
		while true do
			refreshFactorySign()
			task.wait(STATUS_SIGN_REFRESH_SECONDS)
		end
	end)

	-- Coming-Soon marquee flicker loop (SOP §9).
	task.spawn(function()
		while true do
			task.wait(
				flickerRng:NextNumber(
					LobbyConfig.COMING_SOON_FLICKER.MIN_SECONDS,
					LobbyConfig.COMING_SOON_FLICKER.MAX_SECONDS
				)
			)
			flickerOnce()
		end
	end)
end

return HubService
