--!strict
-- CRYPTLINGS: NIGHT SHIFT — noise bus (Stage 1, CONTRACTS v1 §I, §G noise model).
-- The greed dial's transport layer: anything that makes a sound in the factory
-- (squirming cases, sprint footsteps, drops) calls NoiseService.Emit and every
-- subscriber (DefectService's hearing AI, future systems) gets the event.
--
-- Public API (contract I — later stages call these, nothing else):
--   NoiseService.Emit({pos:Vector3, loudness:number, source:Player?,
--                      floorRoot:Instance?, sessionId:string?})
--     floorRoot/sessionId (R2 WP4.1, additive passthrough): the emitter's
--     session floor root / shift id, forwarded untouched to subscribers so
--     per-session Defect AIs (WP4.2) can filter noise to their own floor.
--     Optional — legacy emitters omit them and nothing changes.
--   NoiseService.OnNoise(callback) -> disconnect()   -- server-side fanout
--   NoiseService.SetPlayerCaseMult(player, mult)     -- scent spray sets 0 (Stage 6)
--   NoiseService.GetPlayerCaseMult(player) -> number -- default 1.0
--   NoiseService.PushMeter(player)                   -- convenience: re-push NoiseMeter
--                                                    -- (e.g. CaseService after pickup/drop)
--
-- NoiseMeter (S->C, owner only, contract B): {noise01, carriedCount, maxCarry}.
-- noise01 is the player's current carried-case contribution per contract G:
--   clamp01(carriedCount * NOISE_PER_CARRIED_CASE * caseMult)
-- carriedCount / maxCarry are queried from CaseService via safe require
-- (Stage 1 modules build in parallel — absence degrades to 0 / BASE_CARRY_SLOTS).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConstants = require(Shared:WaitForChild("Config"):WaitForChild("GameConstants"))
local Remotes = require(Shared:WaitForChild("Net"):WaitForChild("Remotes"))
local Util = require(Shared:WaitForChild("Util"))

export type NoiseEvent = {
	pos: Vector3,
	loudness: number,
	source: Player?,
	-- R2 WP4.1 session scoping (additive, optional): the emitting player's
	-- session floor root and shift id — per-session subscribers filter on these.
	floorRoot: Instance?,
	sessionId: string?,
}

type NoiseCallback = (event: NoiseEvent) -> ()

-- Min seconds between NoiseMeter pushes per player. Movement-driven emits can
-- arrive every frame; the meter only reflects carried-case state, so dropping
-- intermediate pushes loses nothing (next emit re-pushes fresh values).
local METER_PUSH_MIN_INTERVAL = 0.15

local NoiseService = {}

--------------------------------------------------------------------------------
-- Internals
--------------------------------------------------------------------------------

local subscribers: { [number]: NoiseCallback } = {}
local nextSubscriberId = 1

-- Per-player case-noise multiplier (contract G: default 1.0; scent spray -> 0).
local caseMults: { [Player]: number } = {}

local lastMeterPushAt: { [Player]: number } = {}

local noiseMeterRemote: RemoteEvent? = nil

-- CaseService is built in parallel (Stage 1) — reach it lazily and safely.
local caseServiceAttempted = false
local caseService: any = nil

local function getCaseService(): any
	if not caseServiceAttempted then
		caseServiceAttempted = true
		local moduleScript = script.Parent and script.Parent:FindFirstChild("CaseService")
		if moduleScript ~= nil and moduleScript:IsA("ModuleScript") then
			local ok, result = pcall(require, moduleScript)
			if ok and type(result) == "table" then
				caseService = result
			else
				warn(`[NoiseService] CaseService require failed: {result}`)
			end
		end
	end
	return caseService
end

-- carriedCount via CaseService.GetCarriedCount (preferred) or #GetCarriedCases;
-- maxCarry via CaseService.GetMaxCarry (contract I). Degrades to 0 / base slots.
local function queryCarryState(player: Player): (number, number)
	local carriedCount = 0
	local maxCarry = GameConstants.BASE_CARRY_SLOTS

	local service = getCaseService()
	if service ~= nil then
		if type(service.GetCarriedCount) == "function" then
			local ok, result = pcall(service.GetCarriedCount, player)
			if ok and type(result) == "number" then
				carriedCount = result
			end
		elseif type(service.GetCarriedCases) == "function" then
			local ok, result = pcall(service.GetCarriedCases, player)
			if ok and type(result) == "table" then
				carriedCount = #result
			end
		end
		if type(service.GetMaxCarry) == "function" then
			local ok, result = pcall(service.GetMaxCarry, player)
			if ok and type(result) == "number" then
				maxCarry = result
			end
		end
	end

	return carriedCount, maxCarry
end

local function pushMeter(player: Player)
	if noiseMeterRemote == nil or player.Parent == nil then
		return
	end

	local carriedCount, maxCarry = queryCarryState(player)
	local noise01 =
		Util.Clamp01(carriedCount * GameConstants.NOISE_PER_CARRIED_CASE * NoiseService.GetPlayerCaseMult(player))

	lastMeterPushAt[player] = os.clock()
	noiseMeterRemote:FireClient(player, {
		noise01 = noise01,
		carriedCount = carriedCount,
		maxCarry = maxCarry,
	})
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- Subscribes to every emitted noise event. Returns a disconnect function.
function NoiseService.OnNoise(callback: NoiseCallback): () -> ()
	assert(type(callback) == "function", "NoiseService.OnNoise: callback must be a function")

	local id = nextSubscriberId
	nextSubscriberId += 1
	subscribers[id] = callback

	return function()
		subscribers[id] = nil
	end
end

-- Emits a noise event to all subscribers and (when source is a Player) pushes
-- the NoiseMeter to that player. Subscriber errors are isolated per callback.
function NoiseService.Emit(event: NoiseEvent)
	if type(event) ~= "table" or typeof(event.pos) ~= "Vector3" or type(event.loudness) ~= "number" then
		warn("[NoiseService] Emit: malformed event dropped (need {pos:Vector3, loudness:number, source:Player?})")
		return
	end
	if event.loudness <= 0 then
		return -- silent events carry no information for hearing AI or the meter
	end
	-- R2 WP4.1: the optional scoping fields are passthrough-only — sanitize a
	-- mistyped field to nil (subscribers treat nil as "unscoped") instead of
	-- dropping an otherwise valid event.
	if event.floorRoot ~= nil and typeof(event.floorRoot) ~= "Instance" then
		event.floorRoot = nil
	end
	if event.sessionId ~= nil and type(event.sessionId) ~= "string" then
		event.sessionId = nil
	end

	for _, callback in subscribers do
		local ok, err = pcall(callback, event)
		if not ok then
			warn(`[NoiseService] OnNoise subscriber error: {err}`)
		end
	end

	local source = event.source
	if source ~= nil and typeof(source) == "Instance" and source:IsA("Player") then
		local lastAt = lastMeterPushAt[source]
		if lastAt == nil or os.clock() - lastAt >= METER_PUSH_MIN_INTERVAL then
			pushMeter(source)
		end
	end
end

-- Per-player case-noise multiplier (contract G). Scent spray sets 0 for the
-- current run (Stage 6); resets to default when the player leaves.
function NoiseService.SetPlayerCaseMult(player: Player, mult: number)
	assert(typeof(player) == "Instance" and player:IsA("Player"), "SetPlayerCaseMult: player required")
	assert(type(mult) == "number" and mult >= 0, "SetPlayerCaseMult: mult must be a number >= 0")

	caseMults[player] = mult
	pushMeter(player) -- meter reflects the new multiplier immediately (bypasses throttle)
end

function NoiseService.GetPlayerCaseMult(player: Player): number
	local mult = caseMults[player]
	if mult ~= nil then
		return mult
	end
	return GameConstants.CASE_NOISE_MULT_DEFAULT
end

-- Re-pushes the NoiseMeter for this player outside of an Emit (e.g. CaseService
-- after a pickup/drop changes carriedCount). Bypasses the throttle.
function NoiseService.PushMeter(player: Player)
	if typeof(player) == "Instance" and player:IsA("Player") then
		pushMeter(player)
	end
end

--------------------------------------------------------------------------------
-- Loader lifecycle
--------------------------------------------------------------------------------

function NoiseService:Init()
	-- Remotes exist before any service Init (init.server contract).
	local ok, remote = pcall(Remotes.GetEvent, "NoiseMeter")
	if ok then
		noiseMeterRemote = remote :: RemoteEvent
	else
		warn(`[NoiseService] NoiseMeter remote unavailable: {remote}`)
	end

	Players.PlayerRemoving:Connect(function(player)
		caseMults[player] = nil
		lastMeterPushAt[player] = nil
	end)
end

return NoiseService
