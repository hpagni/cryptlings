--!strict
-- CRYPTLINGS: NIGHT SHIFT — HousePreviewController (lobby rebuild WP3.7;
-- LOBBY_SOP §5.4 ghost preview; Addendum 2 R3-3 step-plate predicate). When
-- the local player STANDS ON their OWN lot's front step plate, renders a
-- 45%-transparent, non-collidable, decor-flagged greybox shell of the NEXT
-- housing tier over their lot, plus a "+N pet slots" billboard
-- (HouseTransitions.SlotsDelta — sell capacity, not geometry). Destroyed on
-- step-off and on purchase (the plot's HouseTier attribute change).
--
-- Detection (Addendum 2 R3-3) is pure plate-local math at 10 Hz — no touch
-- events (the touch-ended signal false-fires on idle-animation changes), no
-- spatial queries. Every number comes from LobbyConfig.STEP_PLATE and the
-- plate transform is the SAME slot-anchor derivation StreetBuilder places
-- the plate with (stationCFrame * CFrame.new(0, 0, LOCAL_Z)), so the server
-- step and the client predicate can never drift. Three hysteresis layers:
--   1. spatial — ENTER box = exact plate half-extents, EXIT box +1.5 studs
--      all around, so thumbstick wobble at the edge cannot flicker;
--   2. temporal — DWELL_POLLS consecutive in-bounds polls (~0.2 s) before
--      SHOW and the same out-of-bounds before HIDE (no walk-across flash);
--   3. lot-interior veto (the hard rule, overrides everything) — root
--      inside the 45x55 lot footprint hides IMMEDIATELY, no dwell, no exit
--      margin: the ghost can never show while inside the lot.
-- Standing requires FloorMaterial ~= Air (jumping across never counts) and
-- the HRP inside the Y_BAND above the pad-top plane.
--
-- Own-step affordance (client-side, zero Lights): the bound plot's Neon
-- LotStepPlateTrim strips pulse dim<->bright (~1.5 s) while a next tier is
-- buyable, and go dark when HouseTransitions.NextCta(tier) == nil — vacant
-- and maxed lots never advertise. Other players' steps are never touched.
--
-- Pure-client and grants nothing (Security Review Scope §6): geometry comes
-- from HousePlan.GhostPlan — the SAME plan data the server builder renders
-- (R5 D2: exterior walls + parapet + roof slabs + bulkhead ONLY, so the
-- preview is pure massing with no interior/stair/Neon noise) — and the
-- preview can never drift from the house a purchase actually builds; the
-- only inputs are the replicated Plot attribute mirror (LobbyPlotService:
-- tag "Plot", attrs PlotIndex / OwnerUserId / HouseTier) and the local
-- character position. No remotes, no server APIs. Streaming-safe: the
-- player's own plot is PersistentPerPlayer (always streamed for them),
-- every cached instance is revalidated per poll, and trim-tag churn rearms
-- the affordance scan.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local LobbyConfig = require(Shared:WaitForChild("Config"):WaitForChild("LobbyConfig"))
local HousePlan = require(Shared:WaitForChild("Logic"):WaitForChild("HousePlan"))
local HouseTransitions = require(Shared:WaitForChild("Logic"):WaitForChild("HouseTransitions"))

local LocalPlayer = Players.LocalPlayer

--------------------------------------------------------------------------------
-- Tuning (cosmetic, this module's domain — dimensions stay in HousePlan/LobbyConfig)
--------------------------------------------------------------------------------

local TAG_PLOT = "Plot" -- LobbyPlotService tags each plot mirror Model
local TAG_STEP_TRIM = "LotStepPlateTrim" -- StreetBuilder's Neon border strips
local ATTR_OWNER_USER_ID = "OwnerUserId" -- 0 = vacant
local ATTR_HOUSE_TIER = "HouseTier"
local ATTR_PLOT_INDEX = "PlotIndex"

-- 0.1, not 0.2 (Addendum 2 R3-3 / ZonePlus "High" precedent): at 0.2 s a
-- 16-speed walk covers 3.2 studs/sample and can skim the 4-stud-deep plate.
local POLL_SECONDS = 0.1

-- Plate numbers of record — shared with StreetBuilder.buildLotStepPlate;
-- never re-literaled here (config/world lockstep house rule).
local STEP_PLATE = LobbyConfig.STEP_PLATE

-- Lot-interior veto bounds: the 45x55 lot footprint in plot-local space
-- (stationCFrame at lot center on the pad top, -Z streetward — the plate at
-- STEP_PLATE.LOCAL_Z = -29.5 sits fully street-side of the -27.5 front
-- line, so the veto can never fight the stand-on-plate predicate).
local LOT_HALF_X_STUDS = LobbyConfig.LOT_FRONTAGE_STUDS / 2 -- 22.5
local LOT_HALF_Z_STUDS = LobbyConfig.LOT_DEPTH_STUDS / 2 -- 27.5

local COLOR_GHOST = Color3.fromRGB(140, 205, 255) -- pale hologram blue
local COLOR_LABEL_STROKE = Color3.fromRGB(10, 12, 18)

local LABEL_WIDTH_PX = 240
local LABEL_HEIGHT_PX = 56
local LABEL_LIFT_STUDS = 4 -- billboard anchor above the ghost roof

-- Own-step affordance (R3-3 optional scope): the bound plot's trim strips
-- pulse dim<->bright while a next tier is buyable; dark when NextCta(tier)
-- == nil. Bright == the builder's BORDER_COLOR (== COLOR_GHOST) so step and
-- ghost read as one system; restore-on-unbind returns the server color.
local TRIM_COLOR_BRIGHT =
	Color3.fromRGB(STEP_PLATE.BORDER_COLOR.R, STEP_PLATE.BORDER_COLOR.G, STEP_PLATE.BORDER_COLOR.B)
local TRIM_COLOR_DIM = TRIM_COLOR_BRIGHT:Lerp(Color3.new(0, 0, 0), 0.55)
local TRIM_COLOR_DARK = TRIM_COLOR_BRIGHT:Lerp(Color3.new(0, 0, 0), 0.8)
local TRIM_PULSE_SECONDS = 1.5 -- full dim<->bright cycle
local TRIM_TWEEN_INFO =
	TweenInfo.new(TRIM_PULSE_SECONDS / 2, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local HousePreviewController = {}

local myPlot: Model? = nil
local myPlotTierConn: RBXScriptConnection? = nil
local rescanNeeded = true -- full tag re-scan flag (set by tag/attr churn)

local ghostModel: Model? = nil
local ghostTier = -1 -- CURRENT tier the active ghost previews the next step of

-- Step-plate detection state (hysteresis layers 1+2; layer 3 — the
-- lot-interior veto — is stateless and resets everything).
local plateOccupied = false -- SHOW state: standing on the plate
local enterPolls = 0 -- consecutive in-bounds polls while hidden
local exitPolls = 0 -- consecutive out-of-bounds polls while shown
local trackedPlot: Model? = nil -- detection state belongs to ONE plot binding

-- Own-step affordance state (client-local color/tween on replicated trims).
local affordanceIndex: number? = nil -- PlotIndex the trims are styled for
local affordanceLit = false -- pulsing (true) vs dark (false)
local affordanceParts: { BasePart } = {}
local trimTweens: { [BasePart]: Tween } = {}
local trimRescanNeeded = true -- trim tag churn (streaming) rearms the scan

--------------------------------------------------------------------------------
-- Ghost lifecycle
--------------------------------------------------------------------------------

local function destroyGhost()
	if ghostModel ~= nil then
		ghostModel:Destroy()
		ghostModel = nil
	end
	ghostTier = -1
end

-- Decor-flagged ghost primitive (SOP §4.5 display-part discipline, applied
-- client-side: never collides, never blocks queries, casts no shadows).
-- Orientation-capable (R5 D1/D2): when the plan entry carries `orientation`
-- (degrees, stairs-only by contract), the pose composes
-- CFrame.new(offset) * CFrame.Angles(rad(X), rad(Y), rad(Z)) — the same
-- order the server builder applies, so ghost and built poses never diverge.
local function makeGhostPart(parent: Model, plan: HousePlan.ShellPart, stationCFrame: CFrame, color: Color3): BasePart
	local part = Instance.new("Part")
	part.Name = "GhostPart"
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.CastShadow = false
	part.Material = Enum.Material.SmoothPlastic
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Color = color
	part.Transparency = LobbyConfig.GHOST_PREVIEW_TRANSPARENCY
	part.Size = Vector3.new(plan.size.X, plan.size.Y, plan.size.Z)
	local cframe = stationCFrame * CFrame.new(plan.offset.X, plan.offset.Y, plan.offset.Z)
	local orientation = plan.orientation
	if orientation ~= nil then
		cframe = cframe * CFrame.Angles(math.rad(orientation.X), math.rad(orientation.Y), math.rad(orientation.Z))
	end
	part.CFrame = cframe
	part.Parent = parent
	return part
end

-- Builds the next-tier exterior massing over the player's own lot from the
-- SAME HousePlan data the server builder uses (single geometric source of
-- truth). R5 D2: GhostPlan(nextTier) is exterior walls + parapet + roof
-- slabs + bulkhead ONLY (memoized in HousePlan); footprint nesting >= 2
-- studs per side per tier step means no ghost plane is ever coplanar with a
-- built plane — no z-fighting by construction (Addendum 4 §5).
local function buildGhost(stationCFrame: CFrame, currentTier: number)
	destroyGhost()

	local nextTier = currentTier + 1
	local ghostParts = HousePlan.GhostPlan(nextTier)

	local model = Instance.new("Model")
	model.Name = "HouseGhostPreview"

	-- Label anchor height = max top over every GhostPlan entry (bulkhead cap
	-- on T2/T3 previews) so the billboard always clears the silhouette.
	-- GhostPlan entries are axis-aligned by contract (orientation is
	-- stairs-only, and stairs never ship in the ghost), so offset.Y +
	-- size.Y/2 is the exact world-relative top.
	local roofTop = 0
	for _, plan in ghostParts do
		makeGhostPart(model, plan, stationCFrame, COLOR_GHOST)
		roofTop = math.max(roofTop, plan.offset.Y + plan.size.Y / 2)
	end

	-- "+N pet slots" capacity pitch (SOP §5.4: sell capacity, not geometry).
	local slotsDelta = HouseTransitions.SlotsDelta(currentTier)
	if slotsDelta > 0 then
		local anchor = Instance.new("Part")
		anchor.Name = "LabelAnchor"
		anchor.Anchored = true
		anchor.CanCollide = false
		anchor.CanTouch = false
		anchor.CanQuery = false
		anchor.CastShadow = false
		anchor.Transparency = 1
		anchor.Size = Vector3.one
		-- Footprint(nextTier).centerZ: tier footprints differ in depth (R5
		-- D3), so the label centers over the PREVIEWED tier, never a global.
		anchor.CFrame = stationCFrame * CFrame.new(0, roofTop + LABEL_LIFT_STUDS, HousePlan.Footprint(nextTier).centerZ)
		anchor.Parent = model

		local billboard = Instance.new("BillboardGui")
		billboard.Name = "SlotsLabel"
		billboard.Adornee = anchor
		billboard.Size = UDim2.fromOffset(LABEL_WIDTH_PX, LABEL_HEIGHT_PX)
		billboard.MaxDistance = 100 -- preview is range-gated anyway; never street-wide
		billboard.AlwaysOnTop = false
		billboard.LightInfluence = 0 -- the #1 night-sign bug (SOP §11.1)
		billboard.Parent = anchor

		local textColor = LobbyConfig.SIGN_TEXT_COLOR
		local label = Instance.new("TextLabel")
		label.Name = "Text"
		label.BackgroundTransparency = 1
		label.Size = UDim2.fromScale(1, 1)
		label.Font = Enum.Font.GothamBlack
		label.TextScaled = true
		label.TextColor3 = Color3.fromRGB(textColor.R, textColor.G, textColor.B)
		label.Text = `+{slotsDelta} pet slots`
		label.Parent = billboard
		local stroke = Instance.new("UIStroke")
		stroke.Thickness = 2
		stroke.Color = COLOR_LABEL_STROKE
		stroke.Parent = label
	end

	model.Parent = Workspace -- client-local only; never replicates
	ghostModel = model
	ghostTier = currentTier
end

--------------------------------------------------------------------------------
-- Plot binding (replicated attribute mirror; truth stays server-side)
--------------------------------------------------------------------------------

local function unbindPlot()
	if myPlotTierConn ~= nil then
		myPlotTierConn:Disconnect()
		myPlotTierConn = nil
	end
	myPlot = nil
	destroyGhost()
end

local function bindPlot(plot: Model)
	unbindPlot()
	myPlot = plot

	-- Purchase landed (or admin/test override): drop the stale ghost — the
	-- poll rebuilds the new next-tier preview if still standing on the plate.
	myPlotTierConn = plot:GetAttributeChangedSignal(ATTR_HOUSE_TIER):Connect(function()
		destroyGhost()
	end)
end

local function plotIsMine(plot: Model): boolean
	return plot:IsDescendantOf(Workspace) and plot:GetAttribute(ATTR_OWNER_USER_ID) == LocalPlayer.UserId
end

-- Revalidates the cached plot; full tag scan only when flagged stale.
local function ensurePlotBound()
	local current = myPlot
	if current ~= nil and plotIsMine(current) then
		return
	end
	unbindPlot()

	if not rescanNeeded then
		return
	end
	rescanNeeded = false
	for _, instance in CollectionService:GetTagged(TAG_PLOT) do
		if instance:IsA("Model") and plotIsMine(instance) then
			bindPlot(instance)
			return
		end
	end
end

--------------------------------------------------------------------------------
-- Own-step affordance (client-side Neon color only — zero Lights)
--------------------------------------------------------------------------------

-- Styles the bound plot's LotStepPlateTrim strips: pulsing while a next tier
-- is buyable, dark when not, server-bright when unbound. Cheap per poll —
-- re-applies only on plot/CTA change or trim tag churn (streaming).
local function updateStepAffordance(plotIndex: number?, lit: boolean)
	if not trimRescanNeeded and plotIndex == affordanceIndex and lit == affordanceLit then
		return
	end

	-- Restore previously styled strips to the builder's bright border color.
	for _, part in affordanceParts do
		local tween = trimTweens[part]
		if tween ~= nil then
			tween:Cancel()
		end
		if part.Parent ~= nil then
			part.Color = TRIM_COLOR_BRIGHT
		end
	end
	table.clear(affordanceParts)
	table.clear(trimTweens)

	affordanceIndex = plotIndex
	affordanceLit = lit
	trimRescanNeeded = false
	if plotIndex == nil then
		return
	end

	for _, instance in CollectionService:GetTagged(TAG_STEP_TRIM) do
		if instance:IsA("BasePart") and instance:GetAttribute(ATTR_PLOT_INDEX) == plotIndex then
			table.insert(affordanceParts, instance)
			if lit then
				instance.Color = TRIM_COLOR_BRIGHT
				local tween = TweenService:Create(instance, TRIM_TWEEN_INFO, { Color = TRIM_COLOR_DIM })
				trimTweens[instance] = tween
				tween:Play()
			else
				instance.Color = TRIM_COLOR_DARK
			end
		end
	end
end

--------------------------------------------------------------------------------
-- Stand-on-plate poll (Addendum 2 R3-3 — pure math, no touch events/queries)
--------------------------------------------------------------------------------

local function resetPlateDetection()
	plateOccupied = false
	enterPolls = 0
	exitPolls = 0
end

local function poll()
	ensurePlotBound()
	local plot = myPlot
	if plot ~= trackedPlot then
		-- Detection state never survives a rebind (release/assign churn).
		trackedPlot = plot
		resetPlateDetection()
	end
	if plot == nil then
		updateStepAffordance(nil, false)
		destroyGhost()
		return
	end

	local indexValue = plot:GetAttribute(ATTR_PLOT_INDEX)
	local plotIndex = if type(indexValue) == "number" then indexValue else nil

	local tierValue = plot:GetAttribute(ATTR_HOUSE_TIER)
	local tier = if type(tierValue) == "number" then tierValue else 0
	-- Tier cap (or unknown tier): nothing to sell, nothing to preview —
	-- gate on the monetization table of record, never a local copy. The own
	-- step goes dark so vacant/maxed lots never advertise.
	if HouseTransitions.NextCta(tier) == nil then
		updateStepAffordance(plotIndex, false)
		resetPlateDetection()
		destroyGhost()
		return
	end
	updateStepAffordance(plotIndex, true)

	local character = LocalPlayer.Character
	local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
	local humanoid = if character ~= nil then character:FindFirstChildOfClass("Humanoid") else nil
	if root == nil or not root:IsA("BasePart") or humanoid == nil then
		resetPlateDetection()
		destroyGhost()
		return
	end

	local origin = plot.PrimaryPart
	local stationCFrame = if origin ~= nil then origin.CFrame else plot:GetPivot()

	-- Hysteresis layer 3 FIRST — the lot-interior veto overrides everything:
	-- anywhere inside the 45x55 footprint hides IMMEDIATELY, no dwell, no
	-- exit margin ("never inside the lot" is the hard rule).
	local plotLocal = stationCFrame:PointToObjectSpace(root.Position)
	if math.abs(plotLocal.X) <= LOT_HALF_X_STUDS and math.abs(plotLocal.Z) <= LOT_HALF_Z_STUDS then
		resetPlateDetection()
		destroyGhost()
		return
	end

	-- Stand-on-plate predicate: plate-local point check against the SAME
	-- transform StreetBuilder placed the plate with. FloorMaterial ~= Air
	-- means jumping across never counts; the Y band tolerates R15 scaling +
	-- the step lip above the pad-top plane.
	local plateCFrame = stationCFrame * CFrame.new(0, 0, STEP_PLATE.LOCAL_Z)
	local p = plateCFrame:PointToObjectSpace(root.Position)
	local halfX = if plateOccupied then STEP_PLATE.EXIT_HALF_X else STEP_PLATE.ENTER_HALF_X
	local halfZ = if plateOccupied then STEP_PLATE.EXIT_HALF_Z else STEP_PLATE.ENTER_HALF_Z
	local inside = humanoid.FloorMaterial ~= Enum.Material.Air
		and math.abs(p.X) <= halfX
		and math.abs(p.Z) <= halfZ
		and p.Y >= STEP_PLATE.Y_BAND_MIN
		and p.Y <= STEP_PLATE.Y_BAND_MAX

	if plateOccupied then
		-- Hysteresis layer 2 (temporal): DWELL_POLLS misses before HIDE.
		if inside then
			exitPolls = 0
		else
			exitPolls += 1
			if exitPolls >= STEP_PLATE.DWELL_POLLS then
				resetPlateDetection()
				destroyGhost() -- step-off (SOP §5.4 walk-away, plate edition)
			end
		end
	else
		-- DWELL_POLLS consecutive hits before SHOW (no walk-across flash).
		if inside then
			enterPolls += 1
			if enterPolls >= STEP_PLATE.DWELL_POLLS then
				plateOccupied = true
				exitPolls = 0
			end
		else
			enterPolls = 0
		end
	end

	if not plateOccupied then
		return
	end
	if ghostModel ~= nil and ghostTier == tier then
		return -- already showing the right preview
	end
	buildGhost(stationCFrame, tier)
end

--------------------------------------------------------------------------------
-- Loader lifecycle
--------------------------------------------------------------------------------

function HousePreviewController:Init()
	-- Connections only — no instance creation, no yields (§A loader contract).
	CollectionService:GetInstanceAddedSignal(TAG_PLOT):Connect(function()
		rescanNeeded = true
	end)
	CollectionService:GetInstanceRemovedSignal(TAG_PLOT):Connect(function(instance: Instance)
		rescanNeeded = true
		if instance == myPlot then
			unbindPlot()
		end
	end)

	-- Trim streaming churn rearms the affordance scan (late-streamed strips
	-- join the already-known pulse/dark state on the next poll).
	CollectionService:GetInstanceAddedSignal(TAG_STEP_TRIM):Connect(function()
		trimRescanNeeded = true
	end)
	CollectionService:GetInstanceRemovedSignal(TAG_STEP_TRIM):Connect(function()
		trimRescanNeeded = true
	end)
end

function HousePreviewController:Start()
	while true do
		poll()
		-- Ownership attrs can flip without tag churn (assign/release on a
		-- live model): keep the scan armed whenever we hold no plot.
		if myPlot == nil then
			rescanNeeded = true
		end
		task.wait(POLL_SECONDS)
	end
end

return HousePreviewController
