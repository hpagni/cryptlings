--!strict
-- CRYPTLINGS: NIGHT SHIFT — ProfileService-backed player data layer (CONTRACTS v1 §D).
-- Store "PlayerData_v1", key "p_"..userId, session-locked (trading economies die
-- on data loss — SOP §1.5, §8.2). Studio/no-DataStore fallback: in-memory mock
-- profiles, so the place always runs without API access.
--
-- Public API (stable contract — later stages call these, never reach into profiles):
--   PlayerDataService.Get(player) -> Types.ProfileData?     -- nil until loaded
--   PlayerDataService.IsLoaded(player) -> boolean
--   PlayerDataService.Update(player, fn(data)) -> boolean   -- serialized writes
--   PlayerDataService.WithLock(player, fn) -> (ok, result?) -- per-player mutex
--                                                            (trading/monetization
--                                                             dupe prevention)
--   PlayerDataService.EnsureDailyReset(data) -> boolean      -- locker free-open
--                                                             reset at unix-day
--                                                             boundary (§G)
-- Update is serialized per player; fn should not yield. WithLock holds a SEPARATE
-- per-player mutex around multi-step sequences and MAY call Update inside fn.
-- Both locks are re-entrant for the holding thread, so nested service calls that
-- each take the lock cannot deadlock a trade.
--
-- On load this service also maintains profile.lastSeenDay (contract-D field it
-- owns) and fires the CoreLoop step-5 "d1_return" funnel hook (§H) when the
-- player returns exactly one unix day after their last visit. This is the only
-- d1_return detector in the game (Stage 0 integration decision).

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SharedFolder = ReplicatedStorage:WaitForChild("Shared")
local LockerCore = require(SharedFolder:WaitForChild("Logic"):WaitForChild("LockerCore"))
local Types = require(SharedFolder:WaitForChild("Types"))
local Util = require(SharedFolder:WaitForChild("Util"))

local serverRoot = script.Parent.Parent
local ProfileService = require(serverRoot:WaitForChild("Vendor"):WaitForChild("ProfileService")) :: any
local ProfileTemplate = require(serverRoot:WaitForChild("ProfileTemplate"))

local STORE_NAME = "PlayerData_v1"
local KEY_PREFIX = "p_"

--------------------------------------------------------------------------------
-- Per-player mutex (cooperative; FIFO waiters; re-entrant for the holder thread
-- so nested WithLock/Update chains inside trade or purchase flows cannot
-- self-deadlock)
--------------------------------------------------------------------------------

type Lock = { holder: thread, depth: number, waiters: { thread } }
type LockMap = { [Player]: Lock }

local function acquire(locks: LockMap, player: Player)
	local running = coroutine.running()
	local lock = locks[player]
	if lock == nil then
		locks[player] = { holder = running, depth = 1, waiters = {} }
		return
	end
	if lock.holder == running then
		lock.depth += 1 -- re-entrant: the holding thread may nest safely
		return
	end
	table.insert(lock.waiters, running)
	coroutine.yield()
end

local function release(locks: LockMap, player: Player)
	local lock = locks[player]
	if lock == nil then
		return
	end
	if lock.depth > 1 then
		lock.depth -= 1
		return
	end
	local nextThread = table.remove(lock.waiters, 1)
	if nextThread ~= nil then
		lock.holder = nextThread
		lock.depth = 1
		task.spawn(nextThread)
	else
		locks[player] = nil
	end
end

--------------------------------------------------------------------------------
-- Service
--------------------------------------------------------------------------------

local PlayerDataService = {}

local profileStore: any = nil
local profiles: { [Player]: any } = {}
local updateLocks: LockMap = {}
local mutexLocks: LockMap = {}

-- Lazy, optional handle to the sibling AnalyticsService (a parallel Stage 0
-- module). Persistence must never hard-depend on analytics: if the module is
-- missing or broken we silently skip the funnel hook.
local analyticsResolved = false
local analytics: any = nil

local function getAnalytics(): any
	if analyticsResolved then
		return analytics
	end
	analyticsResolved = true
	local servicesFolder = script.Parent
	local module = servicesFolder and servicesFolder:FindFirstChild("AnalyticsService")
	if module ~= nil and module:IsA("ModuleScript") then
		local ok, result = pcall(require, module)
		if ok and type(result) == "table" then
			analytics = result
		end
	end
	return analytics
end

-- Maintains profile.lastSeenDay and fires the CoreLoop step-5 "d1_return"
-- funnel (§H: computed at login from last-seen day). Called once per load,
-- after Reconcile (which fills lastSeenDay = 0 on pre-amendment profiles).
-- This is the SINGLE d1_return source of record — AnalyticsService deliberately
-- has no detector of its own (saves a DataStore read per join).
local function trackReturnVisit(player: Player, data: Types.ProfileData)
	local today = Util.UnixDay()
	local lastSeen = data.lastSeenDay
	data.lastSeenDay = today

	if lastSeen > 0 and today == lastSeen + 1 then
		local service = getAnalytics()
		if service ~= nil and type(service.FunnelStep) == "function" then
			-- AnalyticsService.FunnelStep(player, step, stepName) — CoreLoop funnel.
			pcall(service.FunnelStep, player, 5, "d1_return")
		end
	end
end

-- Publishes the player's cryptling collection as the "TradeCollection" player
-- attribute (JSON {[cryptlingId]: count}) — the client channel TradeUI's trade
-- picker reads (CONTRACTS §B has no collection remote; Stage 4 integration
-- decision). Refreshed on load and after every successful Update, so unbox,
-- trade, and starter-pack grants all propagate without their owners knowing
-- about the channel. No-ops when the encoded payload is unchanged.
local function publishTradeCollection(player: Player, data: Types.ProfileData)
	if typeof(player) ~= "Instance" then
		return -- ForTest player-like fixtures carry no attributes
	end
	local ok, encoded = pcall(function()
		return HttpService:JSONEncode(data.collection)
	end)
	if not ok then
		return
	end
	pcall(function()
		if player:GetAttribute("TradeCollection") ~= encoded then
			player:SetAttribute("TradeCollection", encoded)
		end
	end)
end

local function loadProfile(player: Player)
	if profileStore == nil then
		warn("[PlayerDataService] profile store not ready; cannot load", player.Name)
		return
	end

	local profile = profileStore:LoadProfileAsync(KEY_PREFIX .. player.UserId, "ForceLoad")
	if profile == nil then
		-- DataStore failure or an unreleasable remote session lock. Fail safe:
		-- never run a player on unsaved data (§8.2 — trading economies die on
		-- data loss). Tell them to retry, not that anything was lost.
		player:Kick("Failed to load your data. Please rejoin in a few minutes — your items are safe.")
		return
	end

	profile:AddUserId(player.UserId) -- GDPR right-to-erasure lookup
	profile:Reconcile() -- fill any template keys added since last save

	profile:ListenToRelease(function()
		profiles[player] = nil
		player:Kick("Data loaded on another server. Please rejoin.")
	end)

	if not player:IsDescendantOf(Players) then
		-- Player left while we were loading.
		profile:Release()
		return
	end

	local data = profile.Data :: Types.ProfileData
	PlayerDataService.EnsureDailyReset(data) -- locker free opens, before anything reads them
	profiles[player] = profile
	trackReturnVisit(player, data)
	publishTradeCollection(player, data)
end

function PlayerDataService:Init()
	-- No yields allowed here (loader contract). All setup happens in Start.
end

function PlayerDataService:Start()
	-- Live DataStores outside Studio; in Studio probe once and fall back to
	-- ProfileService's in-memory mock when API access is unavailable.
	local store = ProfileService.GetProfileStore(STORE_NAME, ProfileTemplate)
	local useMock = false
	if RunService:IsStudio() then
		local ok = pcall(function()
			DataStoreService:GetDataStore("__pds_probe__"):GetAsync("__probe__")
		end)
		useMock = not ok
	end
	if useMock then
		warn("[PlayerDataService] DataStores unavailable — using in-memory mock profiles (nothing will persist)")
		profileStore = store.Mock
	else
		profileStore = store
	end

	Players.PlayerAdded:Connect(loadProfile)
	for _, player in Players:GetPlayers() do
		task.spawn(loadProfile, player)
	end

	Players.PlayerRemoving:Connect(function(player)
		local profile = profiles[player]
		if profile ~= nil then
			profile:Release() -- ListenToRelease clears profiles[player]
		end
		-- Lock maps self-clean on release (entry removed when no waiters remain),
		-- so in-flight WithLock/Update chains drain safely after leave.
	end)
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- Returns the player's live profile data, or nil if not (yet) session-locked.
-- The returned table is the live saved state: mutate it ONLY via Update.
function PlayerDataService.Get(player: Player): Types.ProfileData?
	local profile = profiles[player]
	if profile ~= nil then
		return profile.Data :: Types.ProfileData
	end
	return nil
end

function PlayerDataService.IsLoaded(player: Player): boolean
	return profiles[player] ~= nil
end

-- Daily locker reset at the unix-day boundary (00:00 UTC, §G): if a new unix
-- day has started since locker.lastResetDay, zero freeOpensUsed and stamp the
-- new day. Pure over `data` (math lives in Shared.Logic.LockerCore) — called on
-- every profile load and by LockerService before reading/consuming opens (call
-- it inside Update when mutating). Returns true when a reset was applied.
function PlayerDataService.EnsureDailyReset(data: Types.ProfileData): boolean
	return LockerCore.EnsureDailyReset(data.locker, LockerCore.WindowIndex(os.time()))
end

-- Applies fn(data) under the per-player write lock so writes are serialized.
-- Returns false (and does not call fn) if the profile is not loaded; returns
-- false if fn errors (the error is logged, never swallowed silently).
function PlayerDataService.Update(player: Player, fn: (Types.ProfileData) -> ()): boolean
	acquire(updateLocks, player)
	local profile = profiles[player]
	if profile == nil then
		release(updateLocks, player)
		return false
	end
	local ok, err = pcall(fn, profile.Data :: Types.ProfileData)
	release(updateLocks, player)
	if not ok then
		warn(`[PlayerDataService] Update failed for {player.Name}: {err}`)
		return false
	end
	publishTradeCollection(player, profile.Data :: Types.ProfileData)
	return true
end

-- Runs fn under a per-player mutex distinct from the Update lock. Used by
-- trading/monetization to make multi-step sequences (check -> grant -> record)
-- atomic against each other and prevent dupes. fn may yield and may call
-- Update/Get. Returns (true, result) or (false, err).
function PlayerDataService.WithLock(player: Player, fn: () -> any): (boolean, any)
	acquire(mutexLocks, player)
	local ok, result = pcall(fn)
	release(mutexLocks, player)
	if not ok then
		warn(`[PlayerDataService] WithLock body failed for {player.Name}: {result}`)
	end
	return ok, result
end

--------------------------------------------------------------------------------
-- ForTest seams (Studio-only). Locker.spec / TradeService.spec fixtures: a
-- player-like table ({UserId, Name, DisplayName, Parent = nil}) gets a fresh
-- in-memory ProfileTemplate copy, after which Get/IsLoaded/Update/WithLock all
-- work on it exactly like on a real player (the maps are keyed by reference).
-- Nothing persists; inert outside Studio.
--------------------------------------------------------------------------------

-- Loads (or returns the already-loaded) mock profile for a player-like fixture.
-- Returns the profile data, or nil outside Studio / on a bad fixture.
function PlayerDataService.LoadMockProfileForTest(playerLike: any): Types.ProfileData?
	if not RunService:IsStudio() then
		return nil
	end
	if type(playerLike) ~= "table" or playerLike.UserId == nil then
		return nil
	end
	local existing = profiles[playerLike :: any]
	if existing ~= nil then
		return existing.Data :: Types.ProfileData
	end
	local profile = {
		Data = Util.DeepCopy(ProfileTemplate) :: Types.ProfileData,
		Release = function() end,
	}
	profiles[playerLike :: any] = profile
	return profile.Data
end

function PlayerDataService.ReleaseMockProfileForTest(playerLike: any)
	if not RunService:IsStudio() then
		return
	end
	if type(playerLike) == "table" then
		profiles[playerLike :: any] = nil
	end
end

return PlayerDataService
