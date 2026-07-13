--!strict
-- CRYPTLINGS: NIGHT SHIFT — analytics wrapper (CONTRACTS v1 §H, SOP §1.5/§3.4).
-- Wraps Roblox's engine AnalyticsService. EVERY engine call is pcall'd and the
-- whole module no-ops cleanly in Studio/offline — analytics must never break
-- gameplay. Funnel "CoreLoop" (§3.4, live before soft launch):
--   step 1 spawn -> step 2 first_case_pickup -> step 3 extraction
--   -> step 4 first_unboxing -> step 5 d1_return (computed at login)
--
-- Public API (later stages call these, nothing else):
--   AnalyticsService.Track(player, event, props?)  -- custom event, props flattened
--                                                  -- into <=3 custom fields
--   AnalyticsService.FunnelStep(player, step, stepName) -- funnel "CoreLoop"
--   AnalyticsService.FUNNEL_CORE_LOOP = "CoreLoop"
--
-- Owned event sources here: session_start on PlayerAdded and the whitelisted
-- FunnelClient remote (client_spawn_ready / ui_open_shop / ui_open_locker /
-- onboarding_ack; client_spawn_ready also logs funnel step 1 "spawn";
-- ui_open_shop is tracked under its canonical §H name shop_open).
-- d1_return (step 5) is fired by PlayerDataService from profile.lastSeenDay at
-- load — the single source of record (Stage 0 integration decision: the
-- profile-based detector saves a DataStore GetAsync per join, and "CoreLoop"
-- is a one-time funnel anyway). All other events (case_pickup, unbox,
-- purchase, ...) are emitted by their owning services via Track/FunnelStep —
-- see contract H for the canonical list.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local EngineAnalytics = game:GetService("AnalyticsService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Net"):WaitForChild("Remotes"))

local FUNNEL_CORE_LOOP = "CoreLoop"

-- FunnelClient (C->S) whitelist — contract B. Anything else is dropped.
local CLIENT_EVENT_WHITELIST: { [string]: boolean } = {
	client_spawn_ready = true,
	ui_open_shop = true,
	ui_open_locker = true,
	onboarding_ack = true,
}

-- Wire name -> canonical analytics event name (contract §H). The client
-- whitelist keys above stay stable on the wire; dashboards see the canonical
-- name (Stage 6: ShopUI fires ui_open_shop, the §H event is shop_open).
local CLIENT_EVENT_CANONICAL: { [string]: string } = {
	ui_open_shop = "shop_open",
}

local MAX_EVENT_NAME_LENGTH = 100
local MAX_CUSTOM_FIELDS = 3 -- engine limit: CustomField01..03
local MAX_FIELD_LENGTH = 80
local CLIENT_EVENT_MIN_INTERVAL = 5 -- seconds between repeats of one client event

-- Engine analytics only reports outside Studio; in Studio (and in any offline
-- failure mode) every call is a clean no-op.
local isLive = not RunService:IsStudio()

local AnalyticsService = {}

AnalyticsService.FUNNEL_CORE_LOOP = FUNNEL_CORE_LOOP

--------------------------------------------------------------------------------
-- Internals
--------------------------------------------------------------------------------

-- Per-player session state, cleared on leave.
type SessionState = {
	lastClientEventAt: { [string]: number }, -- os.clock() of last accepted client event
	spawnStepLogged: boolean,
}
local sessions: { [Player]: SessionState } = {}

local function getSession(player: Player): SessionState
	local session = sessions[player]
	if session == nil then
		session = { lastClientEventAt = {}, spawnStepLogged = false }
		sessions[player] = session
	end
	return session
end

-- Flattens a props dict into the engine's <=3 string custom fields,
-- deterministically (sorted by key) so dashboards stay stable.
local function toCustomFields(props: { [string]: any }?): { [string]: string }?
	if props == nil then
		return nil
	end

	local keys: { string } = {}
	for key, value in props do
		local valueType = type(value)
		if type(key) == "string" and (valueType == "string" or valueType == "number" or valueType == "boolean") then
			table.insert(keys, key)
		end
	end
	if #keys == 0 then
		return nil
	end
	table.sort(keys)

	local fields: { [string]: string } = {}
	for index = 1, math.min(#keys, MAX_CUSTOM_FIELDS) do
		local key = keys[index]
		local field = string.sub(`{key}={props[key]}`, 1, MAX_FIELD_LENGTH)
		fields[string.format("CustomField%02d", index)] = field
	end
	return fields
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- Logs a custom analytics event for this player. props (optional) is a flat
-- dict of string/number/boolean values; a numeric props.value becomes the
-- event value (defaults to 1). Never errors, never yields, no-op in Studio.
function AnalyticsService.Track(player: Player, event: string, props: { [string]: any }?)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		warn(`[AnalyticsService] Track("{tostring(event)}"): first argument is not a Player — dropped`)
		return
	end
	if type(event) ~= "string" or event == "" or #event > MAX_EVENT_NAME_LENGTH then
		warn(`[AnalyticsService] Track: invalid event name from {player.Name} — dropped`)
		return
	end
	if not isLive then
		return
	end

	local value = 1
	if props ~= nil and type(props.value) == "number" then
		value = props.value
	end

	local ok, err = pcall(function()
		EngineAnalytics:LogCustomEvent(player, event, value, toCustomFields(props))
	end)
	if not ok then
		warn(`[AnalyticsService] LogCustomEvent("{event}") failed: {err}`)
	end
end

-- Logs a step of the one-time "CoreLoop" funnel (§3.4). Steps are 1..5; the
-- engine dedupes repeats of a one-time funnel step per player.
-- Canonical form (contract H/I): FunnelStep(player, step, stepName).
function AnalyticsService.FunnelStep(player: Player, step: number, stepName: string)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		warn(`[AnalyticsService] FunnelStep("{tostring(stepName)}"): first argument is not a Player — dropped`)
		return
	end
	if type(step) ~= "number" or step % 1 ~= 0 or step < 1 or type(stepName) ~= "string" or stepName == "" then
		warn(`[AnalyticsService] FunnelStep: invalid step from {player.Name} — dropped`)
		return
	end
	if not isLive then
		return
	end

	local ok, err = pcall(function()
		EngineAnalytics:LogFunnelStepEvent(player, FUNNEL_CORE_LOOP, nil, step, stepName)
	end)
	if not ok then
		warn(`[AnalyticsService] LogFunnelStepEvent({step} "{stepName}") failed: {err}`)
	end
end

--------------------------------------------------------------------------------
-- Session start
--------------------------------------------------------------------------------

-- (d1_return, funnel step 5, is fired by PlayerDataService from
-- profile.lastSeenDay during profile load — not here.)
local function onPlayerAdded(player: Player)
	getSession(player)
	AnalyticsService.Track(player, "session_start")
end

--------------------------------------------------------------------------------
-- FunnelClient remote (C->S, whitelisted)
--------------------------------------------------------------------------------

local function onFunnelClient(player: Player, payload: any)
	if type(payload) ~= "table" or type(payload.event) ~= "string" then
		return
	end
	local event = payload.event
	if not CLIENT_EVENT_WHITELIST[event] then
		return
	end

	-- Throttle: at most one accepted instance of each client event per
	-- CLIENT_EVENT_MIN_INTERVAL, per player. onboarding_ack is keyed per beat:
	-- the onboarding beats can land <5s apart (ClockIn -> ForemanLine is 3s),
	-- so a flat per-event key would silently drop legitimate acks — each beat
	-- still gets its own spam throttle.
	local throttleKey = event
	if event == "onboarding_ack" and type(payload.props) == "table" and type(payload.props.beat) == "string" then
		throttleKey = `{event}:{string.sub(payload.props.beat, 1, 32)}`
	end
	local session = getSession(player)
	local now = os.clock()
	local lastAt = session.lastClientEventAt[throttleKey]
	if lastAt ~= nil and now - lastAt < CLIENT_EVENT_MIN_INTERVAL then
		return
	end
	session.lastClientEventAt[throttleKey] = now

	local props = if type(payload.props) == "table" then payload.props else nil
	AnalyticsService.Track(player, CLIENT_EVENT_CANONICAL[event] or event, props)

	-- §3.4 funnel step 1: the client reporting "spawned and playable".
	if event == "client_spawn_ready" and not session.spawnStepLogged then
		session.spawnStepLogged = true
		AnalyticsService.FunnelStep(player, 1, "spawn")
	end
end

--------------------------------------------------------------------------------
-- Loader lifecycle
--------------------------------------------------------------------------------

function AnalyticsService:Init()
	-- No yields allowed here (loader contract). Remotes already exist
	-- (init.server runs Remotes.InitServer() before any service Init).
	local okRemote, remote = pcall(Remotes.GetEvent, "FunnelClient")
	if okRemote then
		(remote :: RemoteEvent).OnServerEvent:Connect(function(player: Player, payload: any)
			onFunnelClient(player, payload)
		end)
	else
		warn(`[AnalyticsService] FunnelClient remote unavailable: {remote}`)
	end

	Players.PlayerAdded:Connect(function(player)
		task.spawn(onPlayerAdded, player)
	end)
	Players.PlayerRemoving:Connect(function(player)
		sessions[player] = nil
	end)
end

function AnalyticsService:Start()
	-- Players who joined before this service started (loader races PlayerAdded).
	for _, player in Players:GetPlayers() do
		if sessions[player] == nil then
			task.spawn(onPlayerAdded, player)
		end
	end
end

return AnalyticsService
