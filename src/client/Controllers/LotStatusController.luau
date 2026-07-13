--!strict
-- CRYPTLINGS: NIGHT SHIFT — LotStatusController (Addendum 1 Change 1, plan R2
-- WP3.1, AC-1). Claimed/vacant lot presentation: the server publishes plot
-- ownership as attributes only (LobbyPlotService "Plot" models: PlotIndex /
-- OwnerUserId / OwnerName) and StreetBuilder ships every per-lot fixture in
-- the VACANT state; this controller owns every claim/vacate transition as a
-- LOCAL property tween (server tweens replicate per-step and stutter — SOP
-- addendum standing invariant).
--
--   * Joins the CollectionService tags "Plot" + "LotWash"/"LotTrim"/
--     "LotBeacon"/"LotNameplate" by their PlotIndex attribute, streaming-safe
--     (GetTagged sweep + added/removed signals; fixtures that stream in late
--     snap straight to the current state, no tween storm at join).
--   * CLAIMED (OwnerUserId > 0): 0.5 s tweens (LobbyConfig.LOT_TWEEN_SECONDS)
--     — wash SpotLight to LOT_WASH_CLAIMED (Angle 114, Brightness 2.4, Color
--     = owner accent desaturated 40% toward warm white), Neon trim to opaque
--     accent, beacon pillar + cap from hidden to LOT_BEACON.TRANSPARENCY in
--     the accent, nameplate billboard shows OwnerName. Accent pick is
--     deterministic: LOT_OWNER_ACCENTS[userId % #palette + 1].
--   * VACANT: wash to LOT_WASH_VACANT (0.7 warm-neutral), trim gray at 0.85,
--     beacon hidden, nameplate off.
--   * NEVER creates or destroys a Light instance — property mutation on the
--     EXISTING 20 wash SpotLights only, so the 50-light budget test stays
--     truthful through every transition.
--   * One frame loop throttled to FADE_POLL_SECONDS handles the >= 150-stud
--     camera-distance fade on claimed beacons (0.8 -> 0.95) for <= 20 lots,
--     so the skyline never walls up with pillars.
--
-- Public API (Controllers.Get("LotStatusController")):
--   LotStatusController.GetClaimedLotCount() -> number  -- QA/debug

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local LobbyConfig = require(Shared:WaitForChild("Config"):WaitForChild("LobbyConfig"))

--------------------------------------------------------------------------------
-- Tuning (every number of record lives in LobbyConfig — SOP §9)
--------------------------------------------------------------------------------

-- 3D contract: LobbyPlotService owns "Plot"; StreetBuilder owns the fixtures.
local TAG_PLOT = "Plot"
local TAG_LOT_WASH = "LotWash"
local TAG_LOT_TRIM = "LotTrim"
local TAG_LOT_BEACON = "LotBeacon"
local TAG_LOT_NAMEPLATE = "LotNameplate"

local ATTR_PLOT_INDEX = "PlotIndex"
local ATTR_OWNER_USER_ID = "OwnerUserId"
local ATTR_OWNER_NAME = "OwnerName"

local WASH_CLAIMED = LobbyConfig.LOT_WASH_CLAIMED
local WASH_VACANT = LobbyConfig.LOT_WASH_VACANT
local TRIM_SPEC = LobbyConfig.LOT_TRIM
local BEACON_SPEC = LobbyConfig.LOT_BEACON
local TWEEN_SECONDS = LobbyConfig.LOT_TWEEN_SECONDS -- 0.5 (0.4-0.6 band)
local ACCENT_DESATURATION = LobbyConfig.LOT_WASH_ACCENT_DESATURATION -- 0.4

-- Distance-fade poll cadence: state flips at a 150-stud threshold never need
-- frame accuracy, so the loop early-outs to ~5 Hz.
local FADE_POLL_SECONDS = 0.2

-- StreetBuilder's vacant fixture gray (level-art constant, mirrored here —
-- the builder never exports paint).
local COLOR_FIXTURE_GRAY = Color3.fromRGB(128, 130, 138)
local COLOR_WARM_NEUTRAL = Color3.fromRGB(WASH_VACANT.COLOR.R, WASH_VACANT.COLOR.G, WASH_VACANT.COLOR.B)

local TWEEN_INFO = TweenInfo.new(TWEEN_SECONDS, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)

-- The frozen 8-color accent palette, converted to Color3 once.
local ACCENT_COLORS: { Color3 } = {}
for _, accent in LobbyConfig.LOT_OWNER_ACCENTS :: { { R: number, G: number, B: number } } do
	table.insert(ACCENT_COLORS, Color3.fromRGB(accent.R, accent.G, accent.B))
end

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

type LotRecord = {
	index: number,
	plotModel: Model?,
	washMount: BasePart?,
	washLight: SpotLight?,
	trimParts: { [BasePart]: boolean },
	beaconParts: { [BasePart]: boolean },
	nameplateAnchor: BasePart?,
	claimed: boolean,
	accent: Color3,
	washColor: Color3,
	ownerName: string,
	faded: boolean, -- beacon currently at the far-fade transparency
	tweens: { Tween },
	tweenEndsAt: number, -- fade loop yields to an in-flight claim tween
}

local LotStatusController = {}

local records: { [number]: LotRecord } = {}
-- Per-instance connections (plot attribute listeners, late-child waits),
-- disconnected when that instance untags/streams out.
local watchConnections: { [Instance]: { RBXScriptConnection } } = {}
local fadeAccumulator = 0

--------------------------------------------------------------------------------
-- Records & state targets
--------------------------------------------------------------------------------

local function plotIndexOf(instance: Instance): number?
	local index = instance:GetAttribute(ATTR_PLOT_INDEX)
	return if type(index) == "number" then index else nil
end

local function getRecord(index: number): LotRecord
	local record = records[index]
	if record == nil then
		record = {
			index = index,
			plotModel = nil,
			washMount = nil,
			washLight = nil,
			trimParts = {},
			beaconParts = {},
			nameplateAnchor = nil,
			claimed = false,
			accent = COLOR_FIXTURE_GRAY,
			washColor = COLOR_WARM_NEUTRAL,
			ownerName = "",
			faded = false,
			tweens = {},
			tweenEndsAt = 0,
		}
		records[index] = record
	end
	return record
end

-- Tween toward (claim/vacate transitions) or snap (late-streamed fixtures
-- joining the already-known state).
local function applyProps(record: LotRecord, instance: Instance, props: { [string]: any }, animate: boolean)
	if animate then
		local tween = TweenService:Create(instance, TWEEN_INFO, props)
		table.insert(record.tweens, tween)
		tween:Play()
	else
		for key, value in props do
			(instance :: any)[key] = value
		end
	end
end

local function washTargets(record: LotRecord): { [string]: any }
	if record.claimed then
		return { Angle = WASH_CLAIMED.ANGLE, Brightness = WASH_CLAIMED.BRIGHTNESS, Color = record.washColor }
	end
	return { Angle = WASH_VACANT.ANGLE, Brightness = WASH_VACANT.BRIGHTNESS, Color = COLOR_WARM_NEUTRAL }
end

local function trimTargets(record: LotRecord): { [string]: any }
	if record.claimed then
		return { Color = record.accent, Transparency = 0 }
	end
	return { Color = COLOR_FIXTURE_GRAY, Transparency = TRIM_SPEC.VACANT_TRANSPARENCY }
end

local function beaconTargets(record: LotRecord): { [string]: any }
	if record.claimed then
		local transparency = if record.faded then BEACON_SPEC.FADE_TRANSPARENCY else BEACON_SPEC.TRANSPARENCY
		return { Color = record.accent, Transparency = transparency }
	end
	return { Transparency = 1 }
end

-- Nameplate text/visibility snaps (no transparency tween on gui text — the
-- beacon reveal carries the transition; resolved lazily because the
-- BillboardGui child can replicate after its anchor part).
local function applyNameplate(record: LotRecord)
	local anchor = record.nameplateAnchor
	if anchor == nil then
		return
	end
	local gui = anchor:FindFirstChild("LotNameplate")
	if gui == nil or not gui:IsA("BillboardGui") then
		return
	end
	gui.Enabled = record.claimed
	local label = gui:FindFirstChild("Line1")
	if label ~= nil and label:IsA("TextLabel") then
		label.Text = if record.claimed then record.ownerName else ""
		label.TextColor3 = if record.claimed then record.accent else COLOR_WARM_NEUTRAL
	end
end

local function applyState(record: LotRecord, animate: boolean)
	-- A fresh transition owns every fixture: cancel anything in flight.
	for _, tween in record.tweens do
		tween:Cancel()
	end
	table.clear(record.tweens)
	record.tweenEndsAt = if animate then os.clock() + TWEEN_SECONDS else 0

	local wash = record.washLight
	if wash ~= nil then
		applyProps(record, wash, washTargets(record), animate)
	end
	local trimProps = trimTargets(record)
	for part in record.trimParts do
		applyProps(record, part, trimProps, animate)
	end
	local beaconProps = beaconTargets(record)
	for part in record.beaconParts do
		applyProps(record, part, beaconProps, animate)
	end
	applyNameplate(record)
end

local function refreshOwner(record: LotRecord, animate: boolean)
	local model = record.plotModel
	local ownerAttr = if model ~= nil then model:GetAttribute(ATTR_OWNER_USER_ID) else nil
	local nameAttr = if model ~= nil then model:GetAttribute(ATTR_OWNER_NAME) else nil
	local userId: number = if type(ownerAttr) == "number" then ownerAttr else 0

	record.claimed = userId > 0
	record.ownerName = if type(nameAttr) == "string" then nameAttr else ""
	-- Deterministic accent: every client derives the same color for an owner.
	record.accent = ACCENT_COLORS[userId % #ACCENT_COLORS + 1]
	-- Claimed wash = accent pulled toward warm white (tinted light, not a gel).
	record.washColor = record.accent:Lerp(COLOR_WARM_NEUTRAL, ACCENT_DESATURATION)
	record.faded = false -- re-evaluated by the next fade poll
	applyState(record, animate)
end

--------------------------------------------------------------------------------
-- Tag watchers (streaming-safe: every added fixture snaps to current state)
--------------------------------------------------------------------------------

local function watchPlot(instance: Instance)
	if not instance:IsA("Model") then
		return
	end
	local index = plotIndexOf(instance)
	if index == nil then
		return
	end
	local record = getRecord(index)
	record.plotModel = instance

	local connections: { RBXScriptConnection } = {}
	table.insert(
		connections,
		instance:GetAttributeChangedSignal(ATTR_OWNER_USER_ID):Connect(function()
			refreshOwner(record, true) -- the 0.5 s claim/vacate transition
		end)
	)
	table.insert(
		connections,
		instance:GetAttributeChangedSignal(ATTR_OWNER_NAME):Connect(function()
			-- Name-only repaint: never restarts (or snaps over) the state tween
			-- that the OwnerUserId change just started.
			local nameAttr = instance:GetAttribute(ATTR_OWNER_NAME)
			record.ownerName = if type(nameAttr) == "string" then nameAttr else ""
			applyNameplate(record)
		end)
	)
	watchConnections[instance] = connections

	refreshOwner(record, false) -- initial discovery snaps, no join-time tween
end

local function watchWash(instance: Instance)
	if not instance:IsA("BasePart") then
		return
	end
	local index = plotIndexOf(instance)
	if index == nil then
		return
	end
	local record = getRecord(index)
	record.washMount = instance

	local light = instance:FindFirstChildOfClass("SpotLight")
	if light ~= nil then
		record.washLight = light
		applyProps(record, light, washTargets(record), false)
	else
		-- Streaming is not atomic: the SpotLight child can land after its
		-- mount. One-shot wait, cleaned up if the mount streams back out.
		local connection: RBXScriptConnection? = nil
		connection = instance.ChildAdded:Connect(function(child)
			if child:IsA("SpotLight") then
				if connection ~= nil then
					connection:Disconnect()
				end
				record.washLight = child
				applyProps(record, child, washTargets(record), false)
			end
		end)
		watchConnections[instance] = { connection :: RBXScriptConnection }
	end
end

local function watchTrim(instance: Instance)
	if not instance:IsA("BasePart") then
		return
	end
	local index = plotIndexOf(instance)
	if index == nil then
		return
	end
	local record = getRecord(index)
	record.trimParts[instance] = true
	applyProps(record, instance, trimTargets(record), false)
end

local function watchBeacon(instance: Instance)
	if not instance:IsA("BasePart") then
		return
	end
	local index = plotIndexOf(instance)
	if index == nil then
		return
	end
	local record = getRecord(index)
	record.beaconParts[instance] = true
	applyProps(record, instance, beaconTargets(record), false)
end

local function watchNameplate(instance: Instance)
	if not instance:IsA("BasePart") then
		return
	end
	local index = plotIndexOf(instance)
	if index == nil then
		return
	end
	local record = getRecord(index)
	record.nameplateAnchor = instance
	if instance:FindFirstChild("LotNameplate") ~= nil then
		applyNameplate(record)
	else
		-- Same late-child guard as the wash light, for the BillboardGui.
		local connection: RBXScriptConnection? = nil
		connection = instance.ChildAdded:Connect(function(child)
			if child.Name == "LotNameplate" then
				if connection ~= nil then
					connection:Disconnect()
				end
				applyNameplate(record)
			end
		end)
		watchConnections[instance] = { connection :: RBXScriptConnection }
	end
end

-- Removal: drop the fixture reference and any pending per-instance waits.
-- Last-known lot state is kept — a fixture streaming back in re-snaps to it.
local function unwatch(instance: Instance)
	local connections = watchConnections[instance]
	if connections ~= nil then
		watchConnections[instance] = nil
		for _, connection in connections do
			connection:Disconnect()
		end
	end

	local index = plotIndexOf(instance)
	local record = if index ~= nil then records[index] else nil
	if record == nil then
		return
	end
	if record.plotModel == instance then
		record.plotModel = nil
	end
	if record.washMount == instance then
		record.washMount = nil
		record.washLight = nil
	end
	if record.nameplateAnchor == instance then
		record.nameplateAnchor = nil
	end
	if instance:IsA("BasePart") then
		record.trimParts[instance] = nil
		record.beaconParts[instance] = nil
	end
end

--------------------------------------------------------------------------------
-- Distance fade: claimed beacons drop to FADE_TRANSPARENCY beyond
-- FADE_DISTANCE so 20 pillars never wall up the skyline (AC-1). Throttled;
-- yields to any in-flight claim/vacate tween on the same parts.
--------------------------------------------------------------------------------

local function onFrame(deltaTime: number)
	fadeAccumulator += deltaTime
	if fadeAccumulator < FADE_POLL_SECONDS then
		return
	end
	fadeAccumulator = 0

	local camera = Workspace.CurrentCamera
	if camera == nil then
		return
	end
	local cameraPosition = camera.CFrame.Position
	local now = os.clock()

	for _, record in records do
		if not record.claimed or now < record.tweenEndsAt then
			continue
		end
		local anchor: BasePart? = nil
		for part in record.beaconParts do
			anchor = part
			break
		end
		if anchor == nil then
			continue
		end
		local faded = (anchor.Position - cameraPosition).Magnitude >= BEACON_SPEC.FADE_DISTANCE
		if faded ~= record.faded then
			record.faded = faded
			local transparency = if faded then BEACON_SPEC.FADE_TRANSPARENCY else BEACON_SPEC.TRANSPARENCY
			for part in record.beaconParts do
				part.Transparency = transparency
			end
		end
	end
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

function LotStatusController.GetClaimedLotCount(): number
	local count = 0
	for _, record in records do
		if record.claimed then
			count += 1
		end
	end
	return count
end

--------------------------------------------------------------------------------
-- Loader lifecycle
--------------------------------------------------------------------------------

local TAG_WATCHERS: { [string]: (Instance) -> () } = {
	[TAG_PLOT] = watchPlot,
	[TAG_LOT_WASH] = watchWash,
	[TAG_LOT_TRIM] = watchTrim,
	[TAG_LOT_BEACON] = watchBeacon,
	[TAG_LOT_NAMEPLATE] = watchNameplate,
}

function LotStatusController:Init()
	-- Connections only (Init must not yield). Deferred adds so a just-streamed
	-- instance's attributes replicate before we read them.
	for tag, watcher in TAG_WATCHERS do
		CollectionService:GetInstanceAddedSignal(tag):Connect(function(instance: Instance)
			task.defer(watcher, instance)
		end)
		CollectionService:GetInstanceRemovedSignal(tag):Connect(unwatch)
	end
end

function LotStatusController:Start()
	-- Initial sweep: the street may already be streamed in by the time we run.
	for tag, watcher in TAG_WATCHERS do
		for _, instance in CollectionService:GetTagged(tag) do
			watcher(instance)
		end
	end

	RunService.Heartbeat:Connect(onFrame)
end

return LotStatusController
