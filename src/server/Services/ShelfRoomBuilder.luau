--!strict
-- CRYPTLINGS: NIGHT SHIFT — ShelfRoomBuilder (per-lot CONTENT builder; lobby
-- rebuild WP3.2, SOP §3.3, §4, §12-6/7; module name kept for loader/back-compat).
--
-- StreetBuilder lays the 20 raised lot pads and HubService hands out their
-- anchor frames; LobbyPlotService owns WHO lives on which lot. This module
-- owns WHAT stands on each lot:
--   * At Start every lot gets VACANT DRESSING (SOP §1.2 — never bare greybox):
--     low fence, "FOR SALE" sign, porch lamp, and 8 podiums in empty-state
--     styling on the HousePlan tier-0 layout (<= PART_BUDGET_VACANT_LOT parts,
--     asserted via PartKit.CountParts).
--   * Occupancy is driven by LobbyPlotService.OccupantChanged (pcall sibling);
--     a join-order fallback assignment runs ONLY when LobbyPlotService is
--     missing (test places).
--   * Two-phase populate (SOP §3.3): Phase 1 is instant and synchronous —
--     owner attributes + the sign flips to "Loading shelf…". Phase 2 waits for
--     profile.housing.tier (poll PlayerDataService.IsLoaded, liveness
--     re-checked after every yield), then builds the tier structure from
--     HousePlan.ShellPlan/SlotLayouts FULLY UNPARENTED, Model:PivotTo the lot
--     anchor, and parents ONCE (single replication burst, no half-built
--     houses). No welds anywhere. On tier change (3 s reconciler) the whole
--     content Model is replaced — never mutated in place.
--   * Podium template (SOP §4.2): cylinder plinth 3 dia x 0.75 SmoothPlastic
--     dark gray + 0.15-stud Neon rarity ring. Empty ring = gray; filled ring =
--     RarityTable.RARITY_COLORS[rarity]. NO pet figure models are built
--     server-side — pads replicate descriptors only and the client
--     PodiumDisplayController builds the figures (SOP §3.5/§10).
--   * Owner sign (R5 plan D5: apron (-16, -25), chassis yawed 15° to street;
--     post + plate + tier-identity Neon trim frame): DisplayName + tier name
--     + the state-gated
--     CTA line from HouseTransitions.NextCta (label via pcall
--     MonetizationService.GetHousingCtaText, fallback LobbyConfig copy) +
--     ProximityPrompt -> pcall MonetizationService.PromptNextHousing for the
--     TRIGGERING player only (server-side SKU selection; never the lot).
--
-- 3D contract (consumed by ShelfUI/PodiumDisplayController via
-- CollectionService — UNCHANGED):
--   * Slot pads: tag "ShelfSlotPad"; attrs SlotId ("s1"..), SlotLabel,
--     OwnerUserId (0 = vacant), DoorIndex (lot index), Side, Filled,
--     CryptlingId (while filled); child Highlight "EditGlow" (disabled) +
--     SelectionBox "EmptyOutline"; CanQuery true (ShelfUI raycasts pads).
--   * Entrances: invisible anchor tag "ShelfRoomEntrance" attr OwnerUserId.
--   * Visit tracking: invisible Touched volume per owned lot (analytics).
--   Slot ids: "s1".."s8" tier 0, up to "s1".."s60" Mansion (no leading zeros).
--
-- Public API (names kept for back-compat with earlier stages):
--   ShelfRoomBuilder.NotifyShelfChanged(ownerUserId, slots) -- pad attrs only
--   ShelfRoomBuilder.GetRoomForOwner(userId) -> Model?
--   ShelfRoomBuilder.GetDoorIndexForOwner(userId) -> number?  -- lot index
--   ShelfRoomBuilder.GetSlotPads(userId) -> { [slotId]: BasePart }?
--   ShelfRoomBuilder.IsCorridorActivated() -> boolean         -- true once started

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConstants = require(Shared:WaitForChild("Config"):WaitForChild("GameConstants"))
local LobbyConfig = require(Shared:WaitForChild("Config"):WaitForChild("LobbyConfig"))
local RarityTable = require(Shared:WaitForChild("Config"):WaitForChild("RarityTable"))
local HousePlan = require(Shared:WaitForChild("Logic"):WaitForChild("HousePlan"))
local HouseTransitions = require(Shared:WaitForChild("Logic"):WaitForChild("HouseTransitions"))

-- PartKit lives in the LobbyBuild folder (plain module folder — the frozen
-- loader only auto-loads ModuleScripts directly under Services/).
local PartKit = require(script.Parent:WaitForChild("LobbyBuild"):WaitForChild("PartKit"))

--------------------------------------------------------------------------------
-- Tuning
--------------------------------------------------------------------------------

local LOT_COUNT = GameConstants.HUB_DISPLAY_STATION_COUNT -- 20 lots
local HOUSING_MAX_TIER = GameConstants.HOUSING_MAX_TIER -- 3
local PART_BUDGET_LOT = GameConstants.PART_BUDGET_LOT -- per-lot warn budget
local PART_BUDGET_VACANT = LobbyConfig.PART_BUDGET_VACANT_LOT -- 60, hard assert
-- R5 (plan D4): tiered whole-lot caps {160, 240, 450}, hard-asserted via
-- PartKit.CountParts on every owned build (the flat 400 shell cap is gone).
local PART_BUDGET_HOUSE_BY_TIER = LobbyConfig.PART_BUDGET_HOUSE_BY_TIER

local RECONCILE_SECONDS = 3 -- tier-upgrade + shelf-drift safety net cadence
local PROFILE_WAIT_SECONDS = 15 -- bounded Phase-2 wait; degrade to tier 0 past it
local PROFILE_POLL_SECONDS = 0.25
local VISIT_DEBOUNCE_SECONDS = 60

local LOT_HALF_FRONTAGE = LobbyConfig.LOT_FRONTAGE_STUDS / 2 -- 22.5
local LOT_HALF_DEPTH = LobbyConfig.LOT_DEPTH_STUDS / 2 -- 27.5

local PLINTH_DIAMETER = LobbyConfig.PODIUM.PLINTH_DIAMETER_STUDS -- 3
local PLINTH_HEIGHT = LobbyConfig.PODIUM.PLINTH_HEIGHT_STUDS -- 0.75
local RING_HEIGHT = LobbyConfig.PODIUM.RING_HEIGHT_STUDS -- 0.15

-- Lot-front fixtures (lot-local frame: y 0 = pad top, -Z faces the street).
-- R5 (plan D5; Addendum 4 §1.0): the owner sign lives in the street apron at
-- (-16, -25), yawed 15 degrees toward the street — outside every tier's
-- footprint, so it survives tier rebuilds untouched. The vacant FOR SALE sign
-- shares the position/yaw. The porch lamp is vacant dressing (untouched by
-- R5) and keeps its pre-R5 z.
local SIGN_X = -16
local SIGN_Z = -25
local SIGN_YAW_DEGREES = 15
local PORCH_LAMP_X = 7
local PORCH_LAMP_Z = -(LOT_HALF_DEPTH - 3.5) -- -24
local FENCE_INSET = 0.5
local FENCE_HEIGHT = 1.2
local FENCE_GATE_HALF_WIDTH = 3 -- front fence gap over the footpath

local TIER_NAMES: { [number]: string } = { [0] = "Starter Lot", [1] = "House", [2] = "2-Story House", [3] = "Mansion" }

-- Night greybox palette (level-art only; thematic colors live in LobbyConfig).
local COLOR_PLINTH = Color3.fromRGB(58, 56, 62) -- SmoothPlastic dark gray
local COLOR_RING_EMPTY = Color3.fromRGB(110, 110, 120) -- gray ring ~50% brightness
local COLOR_SIGN = Color3.fromRGB(24, 22, 28)
local COLOR_TRIM = Color3.fromRGB(92, 74, 60)
local COLOR_FENCE = Color3.fromRGB(96, 86, 78)
local COLOR_LAMP_WARM = Color3.fromRGB(255, 196, 120)
local COLOR_EDIT_GLOW = Color3.fromRGB(70, 140, 255)
local COLOR_GOLD = Color3.fromRGB(235, 190, 52)
local COLOR_TEXT_DIM = Color3.fromRGB(200, 200, 200)
local COLOR_FOR_SALE = Color3.fromRGB(255, 170, 90)

local TAG_SLOT_PAD = "ShelfSlotPad"
local TAG_STATION = "ShelfRoom"
local TAG_ENTRANCE = "ShelfRoomEntrance"

--------------------------------------------------------------------------------
-- Sibling services (loader pattern — safe pcall-require, never a hard dep)
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

-- Housing tier of record: ShelfService owns it; fall back to the raw profile,
-- default 0 (starter lot — fail-safe).
local function housingTierOf(player: Player): number
	local shelf = getSibling("ShelfService")
	if shelf ~= nil and type(shelf.GetHousingTier) == "function" then
		local ok, tier = pcall(shelf.GetHousingTier, player)
		if ok and type(tier) == "number" then
			return math.clamp(math.floor(tier), 0, HOUSING_MAX_TIER)
		end
	end
	local pds = getSibling("PlayerDataService")
	if pds ~= nil and type(pds.Get) == "function" then
		local ok, data = pcall(pds.Get, player)
		if ok and type(data) == "table" and type((data :: any).housing) == "table" then
			local tier = (data :: any).housing.tier
			if type(tier) == "number" then
				return math.clamp(math.floor(tier), 0, HOUSING_MAX_TIER)
			end
		end
	end
	return 0
end

local function getProfileShelfSlots(player: Player): { [string]: string }?
	local pds = getSibling("PlayerDataService")
	if pds == nil or type(pds.Get) ~= "function" then
		return nil
	end
	local ok, data = pcall(pds.Get, player)
	if not ok or type(data) ~= "table" then
		return nil
	end
	local shelf = (data :: any).shelf
	if type(shelf) ~= "table" or type(shelf.slots) ~= "table" then
		return nil
	end
	return shelf.slots
end

-- CTA label of record: live GetProductInfo-fed text from MonetizationService
-- (WP3.4) when available, LobbyConfig's verbatim SOP copy otherwise. nil at
-- the tier cap — no CTA to render.
local function housingCtaText(player: Player, tier: number): string?
	if HouseTransitions.NextCta(tier) == nil then
		return nil
	end
	local monetization = getSibling("MonetizationService")
	if monetization ~= nil and type(monetization.GetHousingCtaText) == "function" then
		local ok, text = pcall(monetization.GetHousingCtaText, player)
		if ok and type(text) == "string" and text ~= "" then
			return text
		end
	end
	return LobbyConfig.HOUSING_CTA_FALLBACK[tier]
end

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

type StationSlot = { index: number, stationCFrame: CFrame }

type LotState = {
	index: number,
	slot: StationSlot,
	model: Model,
	owner: Player?,
	ownerUserId: number,
	tier: number, -- -1 = vacant dressing / Phase 2 pending
	generation: number, -- bumped on every occupant change; stale spawns abort
	pads: { [string]: BasePart },
	rings: { [string]: BasePart },
	signTitle: TextLabel?,
	signSubtitle: TextLabel?,
}

local ShelfRoomBuilder = {}

local rootModel: Model? = nil
local stationSlots: { StationSlot } = {}
local stations: { [number]: LotState } = {}
local started = false

-- Join-order fallback assignment — used ONLY when LobbyPlotService is missing.
local fallbackOwnerByIndex: { [number]: Player } = {}
local fallbackIndexByPlayer: { [Player]: number } = {}
local fallbackOverflow: { Player } = {}

local lastVisitAt: { [string]: number } = {}
local warnedUnknownIds: { [string]: boolean } = {}

local function ensureRootModel(): Model
	local existing = rootModel
	if existing ~= nil and existing.Parent ~= nil then
		return existing
	end
	local model = Instance.new("Model")
	model.Name = "PlayerLotBuildings"
	model.Parent = Workspace
	rootModel = model
	return model
end

local function playerFromHit(hit: BasePart): Player?
	local model = hit:FindFirstAncestorOfClass("Model")
	while model ~= nil do
		local player = Players:GetPlayerFromCharacter(model)
		if player ~= nil then
			return player
		end
		model = model:FindFirstAncestorOfClass("Model")
	end
	return nil
end

--------------------------------------------------------------------------------
-- Pad styling (descriptors only — figures are client-built)
--------------------------------------------------------------------------------

local function rarityColorFor(cryptlingId: string): Color3
	local def: any = RarityTable.GetCryptling(cryptlingId)
	if def == nil then
		if not warnedUnknownIds[cryptlingId] then
			warnedUnknownIds[cryptlingId] = true
			warn(`[ShelfRoomBuilder] unknown cryptlingId "{cryptlingId}" on lot — gray ring`)
		end
		return COLOR_RING_EMPTY
	end
	local color = (RarityTable.RARITY_COLORS :: any)[def.rarity]
	return if typeof(color) == "Color3" then color else COLOR_RING_EMPTY
end

-- The ONE place pad descriptors mutate: attributes + ring color + outline.
local function setPadContents(station: LotState, slotId: string, cryptlingId: string?)
	local pad = station.pads[slotId]
	if pad == nil then
		return
	end
	local ring = station.rings[slotId]
	local outline = pad:FindFirstChild("EmptyOutline")
	if cryptlingId == nil then
		pad:SetAttribute("Filled", false)
		pad:SetAttribute("CryptlingId", nil)
		if ring ~= nil then
			ring.Color = COLOR_RING_EMPTY
		end
		if outline ~= nil and outline:IsA("SelectionBox") then
			outline.Transparency = 0.45
		end
	else
		pad:SetAttribute("Filled", true)
		pad:SetAttribute("CryptlingId", cryptlingId)
		if ring ~= nil then
			ring.Color = rarityColorFor(cryptlingId)
		end
		if outline ~= nil and outline:IsA("SelectionBox") then
			outline.Transparency = 1
		end
	end
end

-- Diff pad attributes against a shelf snapshot ({ [slotId]: cryptlingId }).
local function reconcilePads(station: LotState, slots: { [string]: string? })
	for slotId, pad in station.pads do
		local want = slots[slotId]
		local have = pad:GetAttribute("CryptlingId")
		local filled = pad:GetAttribute("Filled") == true
		if want == nil then
			if filled or have ~= nil then
				setPadContents(station, slotId, nil)
			end
		elseif not filled or have ~= want then
			setPadContents(station, slotId, want)
		end
	end
end

local function reconcilePadsFromProfile(station: LotState)
	local owner = station.owner
	if owner == nil or owner.Parent ~= Players then
		return
	end
	local slots = getProfileShelfSlots(owner)
	if slots ~= nil then
		reconcilePads(station, slots :: { [string]: string? })
	end
end

--------------------------------------------------------------------------------
-- Lot-local construction helpers. Everything builds in the lot frame (y 0 =
-- pad top, -Z faces the street) on an UNPARENTED Model whose WorldPivot is
-- pinned to identity; the caller PivotTo's the lot anchor and parents once.
--------------------------------------------------------------------------------

-- Podium template (SOP §4.2): plinth + Neon rarity ring + invisible query pad
-- carrying the full ShelfSlotPad contract. 3 parts per podium of record
-- (HousePlan.PARTS_PER_PODIUM).
local function buildPodiums(model: Model, station: LotState, tier: number)
	for _, layout in HousePlan.SlotLayouts(math.max(tier, 0)) do
		local plinth = PartKit.MakeUprightCylinder(
			model,
			`Plinth_{layout.slotId}`,
			PLINTH_HEIGHT,
			PLINTH_DIAMETER,
			Vector3.new(layout.x, layout.y + PLINTH_HEIGHT / 2, layout.z),
			{ color = COLOR_PLINTH }
		)
		plinth.CanCollide = true

		local ring = PartKit.MakeUprightCylinder(
			model,
			`Ring_{layout.slotId}`,
			RING_HEIGHT,
			PLINTH_DIAMETER,
			Vector3.new(layout.x, layout.y + PLINTH_HEIGHT + RING_HEIGHT / 2, layout.z),
			{ color = COLOR_RING_EMPTY, material = Enum.Material.Neon, decor = true }
		)

		local pad = PartKit.MakePart(
			model,
			`Pad_{layout.slotId}`,
			Vector3.new(1.6, 0.2, 1.6),
			CFrame.new(layout.x, layout.y + PLINTH_HEIGHT + RING_HEIGHT + 0.1, layout.z),
			{ transparency = 1, decor = true, canQuery = true } -- ShelfUI raycasts pads
		)
		pad:SetAttribute("SlotId", layout.slotId)
		pad:SetAttribute("SlotLabel", layout.slotLabel)
		pad:SetAttribute("OwnerUserId", station.ownerUserId)
		pad:SetAttribute("DoorIndex", station.index)
		pad:SetAttribute("Side", 1)
		pad:SetAttribute("Filled", false)
		CollectionService:AddTag(pad, TAG_SLOT_PAD)

		local outline = Instance.new("SelectionBox")
		outline.Name = "EmptyOutline"
		outline.Adornee = pad
		outline.LineThickness = 0.04
		outline.Color3 = COLOR_RING_EMPTY
		outline.Transparency = 0.45
		outline.Parent = pad

		local editGlow = Instance.new("Highlight")
		editGlow.Name = "EditGlow"
		editGlow.Enabled = false
		editGlow.Adornee = pad
		editGlow.FillColor = COLOR_EDIT_GLOW
		editGlow.OutlineColor = COLOR_EDIT_GLOW
		editGlow.FillTransparency = 0.55
		editGlow.OutlineTransparency = 0.1
		editGlow.DepthMode = Enum.HighlightDepthMode.Occluded
		editGlow.Parent = pad

		station.pads[layout.slotId] = pad
		station.rings[layout.slotId] = ring
	end
end

-- Plan colors are frozen { R, G, B } 0-255 tables; Color3.fromRGB happens
-- HERE, at apply time only (plan D8 — assigning a raw table to a Color3
-- property has crashed boot twice in past rounds).
type PlanRGB = { R: number, G: number, B: number }

local function applyRGB(color: PlanRGB): Color3
	return Color3.fromRGB(color.R, color.G, color.B)
end

-- Tier identity Neon color of record (T1 amber / T2 cyan / T3 magenta,
-- Addendum 4 §1.0). Starter lots carry no identity yet — warm lamp glow.
local function tierTrimColor(tier: number): Color3
	if tier >= 1 then
		return applyRGB(LobbyConfig.HOUSE_PALETTE.TIER_IDENTITY[math.min(tier, HOUSING_MAX_TIER)])
	end
	return COLOR_LAMP_WARM
end

-- House/mansion shell straight from HousePlan.ShellPlan — the same plan data
-- the client ghost preview renders, so the purchase always builds what was
-- shown. R5 (plan D2): five categories — walls/slabs/stairs are collidable
-- structure; windows/neon are non-collidable Neon decor. Stair planks carry
-- an `orientation` field (degrees, X-axis only by contract, ±atan(rise/run)
-- generator-derived); the builder composes it into the CFrame here — PartKit
-- itself is unchanged. Per-part `color` overrides (T3 window gradient,
-- per-floor accents) win over the category default from HOUSE_PALETTE.
local function buildShell(model: Model, tier: number)
	local shell = HousePlan.ShellPlan(tier)
	local palette = LobbyConfig.HOUSE_PALETTE
	local identity: PlanRGB = palette.TIER_IDENTITY[math.clamp(tier, 1, HOUSING_MAX_TIER)]

	local function emit(parts: { HousePlan.ShellPart }, namePrefix: string, defaultColor: PlanRGB, neonDecor: boolean)
		for index, part in parts do
			local cf = CFrame.new(part.offset.X, part.offset.Y, part.offset.Z)
			local orientation = part.orientation
			if orientation ~= nil then
				cf = cf * CFrame.Angles(math.rad(orientation.X), math.rad(orientation.Y), math.rad(orientation.Z))
			end
			local props: PartKit.PartProps = if neonDecor
				then { color = applyRGB(part.color or defaultColor), material = Enum.Material.Neon, decor = true }
				else { color = applyRGB(part.color or defaultColor), canCollide = true }
			PartKit.MakePart(
				model,
				`{namePrefix}{index}`,
				Vector3.new(part.size.X, part.size.Y, part.size.Z),
				cf,
				props
			)
		end
	end

	emit(shell.walls, "Wall", palette.CHARCOAL, false)
	emit(shell.slabs, "Slab", palette.CHARCOAL, false)
	emit(shell.stairs, "Stair", palette.SLATE, false)
	emit(shell.windows, "Window", identity, true)
	emit(shell.neon, "Neon", identity, true)
end

-- Shared sign chassis: post + plate + 4-strip Neon trim frame (6 parts, the
-- Addendum 4 §1.0 assembly of record), two stacked labels. R5 (plan D5): the
-- whole assembly composes off ONE chassis CFrame at the apron position
-- (-16, -25), yawed 15 degrees toward the street — owned and vacant signs
-- share it. Every part is decor (non-collidable): the apron strip holds zero
-- collidable house parts at any tier (AC-R5.5). Trim takes the tier identity
-- color so the sign joins the house's night glow system.
local function buildSign(
	model: Model,
	titleText: string,
	titleColor: Color3,
	subtitleText: string,
	trimColor: Color3
): (TextLabel, TextLabel)
	local chassis = CFrame.new(SIGN_X, 0, SIGN_Z) * CFrame.Angles(0, math.rad(SIGN_YAW_DEGREES), 0)
	local post = PartKit.MakePart(
		model,
		"SignPost",
		Vector3.new(0.4, 3.4, 0.4),
		chassis * CFrame.new(0, 1.7, 0),
		{ color = COLOR_TRIM, decor = true }
	)
	local plate = PartKit.MakePart(
		model,
		"SignPlate",
		Vector3.new(7, 3, 0.4),
		chassis * CFrame.new(0, 4.4, 0),
		{ color = COLOR_SIGN, decor = true }
	)
	post.CanCollide = false
	plate.CanQuery = true -- ProximityPrompt host on owned lots

	-- Neon trim frame hugging the plate edges (plate face spans x ±3.5,
	-- y 2.9..5.9; strips sit just outside it, 0.5 deep so they read proud of
	-- the 0.4 plate from the street without touching the SurfaceGui face).
	local trimStrips: { { size: Vector3, offset: CFrame } } = {
		{ size = Vector3.new(7.6, 0.3, 0.5), offset = CFrame.new(0, 6.05, 0) },
		{ size = Vector3.new(7.6, 0.3, 0.5), offset = CFrame.new(0, 2.75, 0) },
		{ size = Vector3.new(0.3, 3, 0.5), offset = CFrame.new(-3.65, 4.4, 0) },
		{ size = Vector3.new(0.3, 3, 0.5), offset = CFrame.new(3.65, 4.4, 0) },
	}
	for stripIndex, strip in trimStrips do
		PartKit.MakePart(model, `SignTrim{stripIndex}`, strip.size, chassis * strip.offset, {
			color = trimColor,
			material = Enum.Material.Neon,
			decor = true,
		})
	end

	local gui = PartKit.MakeSurfaceGui(plate, "SignGui")
	local title =
		PartKit.MakeLabel(gui, "Title", titleText, UDim2.fromScale(0.03, 0.05), UDim2.fromScale(0.94, 0.42), titleColor)
	local subtitle = PartKit.MakeLabel(
		gui,
		"Subtitle",
		subtitleText,
		UDim2.fromScale(0.03, 0.5),
		UDim2.fromScale(0.94, 0.44),
		COLOR_TEXT_DIM
	)
	return title, subtitle
end

-- Vacant dressing (SOP §1.2): low fence, FOR SALE sign, porch lamp. The lawn
-- is the StreetBuilder lot pad itself; everything here is decor-flagged.
local function buildVacantDressing(model: Model)
	local fx = LOT_HALF_FRONTAGE - FENCE_INSET -- 22
	local fz = LOT_HALF_DEPTH - FENCE_INSET -- 27
	local railY = FENCE_HEIGHT / 2
	local frontSegment = fx - FENCE_GATE_HALF_WIDTH -- 19 each side of the gate

	local rails: { { size: Vector3, cframe: CFrame } } = {
		{
			size = Vector3.new(frontSegment, FENCE_HEIGHT, 0.3),
			cframe = CFrame.new(-(FENCE_GATE_HALF_WIDTH + frontSegment / 2), railY, -fz),
		},
		{
			size = Vector3.new(frontSegment, FENCE_HEIGHT, 0.3),
			cframe = CFrame.new(FENCE_GATE_HALF_WIDTH + frontSegment / 2, railY, -fz),
		},
		{ size = Vector3.new(fx * 2, FENCE_HEIGHT, 0.3), cframe = CFrame.new(0, railY, fz) },
		{ size = Vector3.new(0.3, FENCE_HEIGHT, fz * 2), cframe = CFrame.new(-fx, railY, 0) },
		{ size = Vector3.new(0.3, FENCE_HEIGHT, fz * 2), cframe = CFrame.new(fx, railY, 0) },
	}
	for railIndex, rail in rails do
		PartKit.MakePart(model, `FenceRail{railIndex}`, rail.size, rail.cframe, { color = COLOR_FENCE, decor = true })
	end
	for postIndex, corner in
		{ Vector3.new(-fx, 0, -fz), Vector3.new(fx, 0, -fz), Vector3.new(-fx, 0, fz), Vector3.new(fx, 0, fz) }
	do
		PartKit.MakePart(
			model,
			`FencePost{postIndex}`,
			Vector3.new(0.5, FENCE_HEIGHT + 0.6, 0.5),
			CFrame.new(corner.X, (FENCE_HEIGHT + 0.6) / 2, corner.Z),
			{ color = COLOR_TRIM, decor = true }
		)
	end

	-- Porch lamp: Neon bulb only — NO Light instance (the per-lot wash is
	-- StreetBuilder's; 20 extra lot lights would blow the 50-light budget).
	PartKit.MakePart(
		model,
		"PorchLampPost",
		Vector3.new(0.3, 4, 0.3),
		CFrame.new(PORCH_LAMP_X, 2, PORCH_LAMP_Z),
		{ color = COLOR_TRIM, decor = true }
	)
	PartKit.MakePart(
		model,
		"PorchLampBulb",
		Vector3.new(0.8, 0.8, 0.8),
		CFrame.new(PORCH_LAMP_X, 4.4, PORCH_LAMP_Z),
		{ color = COLOR_LAMP_WARM, material = Enum.Material.Neon, decor = true }
	)
end

local function buildEntranceAnchor(model: Model, station: LotState, tier: number)
	-- R5: anchor derives from HousePlan.Footprint(tier) — mid-height of the
	-- 7w x 7h front door (Addendum 4 §1.0) on the front wall plane.
	local anchorCFrame: CFrame
	if tier >= 1 then
		local footprint = HousePlan.Footprint(tier)
		anchorCFrame = CFrame.new(0, footprint.ffl1 + 3.5, footprint.frontZ)
	else
		anchorCFrame = CFrame.new(0, 3, -14)
	end
	local anchor = PartKit.MakePart(
		model,
		"EntranceAnchor",
		Vector3.new(4, 0.5, 0.5),
		anchorCFrame,
		{ transparency = 1, decor = true }
	)
	anchor:SetAttribute("OwnerUserId", station.ownerUserId)
	CollectionService:AddTag(anchor, TAG_ENTRANCE)
end

-- Visit-tracking Touched volume across the lot front (analytics, kept).
local function buildVisitTrigger(model: Model, station: LotState)
	local trigger = PartKit.MakePart(
		model,
		"VisitTrigger",
		Vector3.new(24, 8, 12),
		CFrame.new(0, 4, -(LOT_HALF_DEPTH - 6)),
		{ transparency = 1, decor = true }
	)
	trigger.CanTouch = true
	trigger.Touched:Connect(function(hit)
		local ownerUserId = station.ownerUserId
		if ownerUserId <= 0 then
			return
		end
		local visitor = playerFromHit(hit)
		if visitor == nil or visitor.UserId == ownerUserId then
			return
		end
		local key = `{visitor.UserId}_{ownerUserId}`
		local now = os.clock()
		local last = lastVisitAt[key]
		if last ~= nil and now - last < VISIT_DEBOUNCE_SECONDS then
			return
		end
		lastVisitAt[key] = now
		track(visitor, "hub_visit", { ownerUserId = ownerUserId })
	end)
end

-- Owner sign CTA prompt: server-side SKU selection only. The buyer is ALWAYS
-- the triggering player (re-derived by MonetizationService from its argument,
-- never from the lot), and only the lot owner sees their own next step.
local function wireCtaPrompt(model: Model, station: LotState, owner: Player, tier: number)
	local cta = housingCtaText(owner, tier)
	if cta == nil then
		return -- tier cap: nothing to sell (SOP §5.4 state-gated single CTA)
	end
	local plate = model:FindFirstChild("SignPlate")
	local gui = if plate ~= nil then plate:FindFirstChild("SignGui") else nil
	if plate == nil or not plate:IsA("BasePart") or gui == nil then
		return
	end

	-- Third sign line: the CTA copy (live price text when WP3.4 is wired).
	local title = gui:FindFirstChild("Title")
	local subtitle = gui:FindFirstChild("Subtitle")
	if title ~= nil and title:IsA("TextLabel") then
		title.Size = UDim2.fromScale(0.94, 0.36)
	end
	if subtitle ~= nil and subtitle:IsA("TextLabel") then
		subtitle.Position = UDim2.fromScale(0.03, 0.42)
		subtitle.Size = UDim2.fromScale(0.94, 0.26)
	end
	PartKit.MakeLabel(gui, "CtaLine", cta, UDim2.fromScale(0.03, 0.7), UDim2.fromScale(0.94, 0.26), COLOR_GOLD)

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "HousingCtaPrompt"
	prompt.ObjectText = `{owner.DisplayName}'s Lot`
	prompt.ActionText = if tier <= 0 then "Build House" else "Upgrade House"
	prompt.HoldDuration = 0.25
	prompt.MaxActivationDistance = LobbyConfig.GHOST_PREVIEW_RANGE_STUDS
	prompt.RequiresLineOfSight = false
	prompt.Triggered:Connect(function(triggering)
		if triggering == nil or triggering.UserId ~= station.ownerUserId then
			return -- only the owner's own sign prompts their next step
		end
		local monetization = getSibling("MonetizationService")
		if monetization ~= nil and type(monetization.PromptNextHousing) == "function" then
			pcall(monetization.PromptNextHousing, triggering)
		end
	end)
	prompt.Parent = plate
end

--------------------------------------------------------------------------------
-- Content assembly: build fully unparented, PivotTo the lot anchor, parent
-- once. Replace the whole Model on every state change — never mutate.
--------------------------------------------------------------------------------

local function swapInModel(station: LotState, model: Model)
	model:SetAttribute("StationIndex", station.index)
	model:SetAttribute("OwnerUserId", station.ownerUserId)
	model:SetAttribute("HousingTier", math.max(station.tier, 0))
	CollectionService:AddTag(model, TAG_STATION)
	model.ModelStreamingMode = Enum.ModelStreamingMode.Atomic

	model.WorldPivot = CFrame.identity
	model:PivotTo(station.slot.stationCFrame)

	local old = station.model
	station.model = model
	model.Parent = ensureRootModel()
	if old ~= nil and old ~= model then
		old:Destroy()
	end
end

-- Vacant dressing build (tier "-1"): FOR SALE sign + fence + 8 empty podiums.
local function rebuildVacant(station: LotState)
	station.owner = nil
	station.ownerUserId = 0
	station.tier = -1
	table.clear(station.pads)
	table.clear(station.rings)

	local model = Instance.new("Model")
	model.Name = `VacantLot{station.index}`
	buildVacantDressing(model)
	station.signTitle, station.signSubtitle = buildSign(model, "FOR SALE", COLOR_FOR_SALE, "Vacant Lot", COLOR_FOR_SALE)
	buildPodiums(model, station, 0)

	local total = PartKit.CountParts(model)
	assert(
		total <= PART_BUDGET_VACANT,
		`[ShelfRoomBuilder] vacant lot uses {total} parts — over the {PART_BUDGET_VACANT} SOP cap`
	)
	swapInModel(station, model)
end

-- Owned build (Phase 2 / tier change): shell + podiums + owner sign + CTA.
local function rebuildOwned(station: LotState, owner: Player, tier: number)
	station.owner = owner
	station.ownerUserId = owner.UserId
	station.tier = tier
	table.clear(station.pads)
	table.clear(station.rings)

	local model = Instance.new("Model")
	model.Name = `PlayerLot{station.index}`
	if tier >= 1 then
		buildShell(model, tier)
	end
	buildPodiums(model, station, tier)
	station.signTitle, station.signSubtitle =
		buildSign(model, `{owner.DisplayName}'s Lot`, COLOR_LAMP_WARM, TIER_NAMES[tier] or "", tierTrimColor(tier))
	wireCtaPrompt(model, station, owner, tier)
	buildEntranceAnchor(model, station, tier)
	buildVisitTrigger(model, station)

	local total = PartKit.CountParts(model)
	-- R5 hard caps (plan D4, AC-R5.6): the whole owned lot — shell + stairs +
	-- podiums + sign — must fit the tiered budget; a bust here is a plan bug,
	-- never something to ship.
	if tier >= 1 then
		local cap = PART_BUDGET_HOUSE_BY_TIER[tier]
		assert(total <= cap, `[ShelfRoomBuilder] tier {tier} lot uses {total} parts — over the {cap} R5 tier cap`)
	end
	if total > PART_BUDGET_LOT then
		warn(`[ShelfRoomBuilder] lot {station.index} uses {total} parts — over the {PART_BUDGET_LOT} budget`)
	end
	swapInModel(station, model)
	reconcilePadsFromProfile(station)

	-- Mirror the tier onto LobbyPlotService's plot model (display attr the
	-- client ghost preview watches for purchase-completion teardown).
	local plotService = getSibling("LobbyPlotService")
	if plotService ~= nil and type(plotService.GetPlotByIndex) == "function" then
		pcall(function()
			local plot = plotService.GetPlotByIndex(station.index)
			if plot ~= nil and plot.model ~= nil then
				plot.model:SetAttribute("HouseTier", tier)
			end
		end)
	end
end

-- Phase 2: wait (bounded) for the profile, re-check liveness after EVERY
-- yield, then build the tier structure. A stale generation means the occupant
-- changed under us — newer state already owns the lot; do nothing.
local function populateOwnedLot(station: LotState, owner: Player, generation: number)
	local dataService = getSibling("PlayerDataService")
	if dataService ~= nil and type(dataService.IsLoaded) == "function" then
		local deadline = os.clock() + PROFILE_WAIT_SECONDS
		while not dataService.IsLoaded(owner) do
			if os.clock() >= deadline then
				break -- degrade: tier 0 now; the reconciler upgrades on late load
			end
			task.wait(PROFILE_POLL_SECONDS)
			if station.generation ~= generation then
				return
			end
			if owner.Parent ~= Players then
				return -- left during the profile wait; release path rebuilds vacant
			end
		end
	end
	if station.generation ~= generation or owner.Parent ~= Players then
		return
	end
	rebuildOwned(station, owner, housingTierOf(owner)) -- no yields inside
end

-- Occupancy entry point (LobbyPlotService.OccupantChanged or the fallback).
local function setOccupant(index: number, player: Player?)
	local station = stations[index]
	if station == nil then
		return
	end
	if player ~= nil and station.owner == player then
		return -- idempotent: snapshot duplicates the signal harmlessly
	end
	if player == nil and station.owner == nil and station.tier < 0 then
		return -- already vacant
	end
	station.generation += 1

	if player == nil then
		rebuildVacant(station)
		return
	end

	-- Phase 1 (instant, synchronous): owner attrs + "Loading shelf…" sign on
	-- the standing model; geometry waits for the profile (Phase 2).
	station.owner = player
	station.ownerUserId = player.UserId
	station.tier = -1
	station.model:SetAttribute("OwnerUserId", player.UserId)
	for _, pad in station.pads do
		pad:SetAttribute("OwnerUserId", player.UserId)
	end
	local title = station.signTitle
	if title ~= nil then
		title.Text = `{player.DisplayName}'s Lot`
		title.TextColor3 = COLOR_LAMP_WARM
	end
	local subtitle = station.signSubtitle
	if subtitle ~= nil then
		subtitle.Text = "Loading shelf…"
	end

	task.spawn(populateOwnedLot, station, player, station.generation)
end

--------------------------------------------------------------------------------
-- Join-order fallback assignment (ONLY when LobbyPlotService is missing)
--------------------------------------------------------------------------------

local function fallbackAdd(player: Player)
	if fallbackIndexByPlayer[player] ~= nil then
		return
	end
	for index = 1, math.min(LOT_COUNT, #stationSlots) do
		if fallbackOwnerByIndex[index] == nil then
			fallbackOwnerByIndex[index] = player
			fallbackIndexByPlayer[player] = index
			setOccupant(index, player)
			return
		end
	end
	table.insert(fallbackOverflow, player)
end

local function fallbackRemove(player: Player)
	local index = fallbackIndexByPlayer[player]
	if index == nil then
		local at = table.find(fallbackOverflow, player)
		if at ~= nil then
			table.remove(fallbackOverflow, at)
		end
		return
	end
	fallbackIndexByPlayer[player] = nil
	fallbackOwnerByIndex[index] = nil
	local promoted = table.remove(fallbackOverflow, 1)
	if promoted ~= nil then
		fallbackOwnerByIndex[index] = promoted
		fallbackIndexByPlayer[promoted] = index
		setOccupant(index, promoted)
	else
		setOccupant(index, nil)
	end
end

--------------------------------------------------------------------------------
-- Public API (names kept for back-compat with earlier stages)
--------------------------------------------------------------------------------

local function stationForOwner(userId: number): LotState?
	if userId <= 0 then
		return nil
	end
	for _, station in stations do
		if station.ownerUserId == userId then
			return station
		end
	end
	return nil
end

-- ShelfService hook: same payload as the ShelfChanged remote. Updates pad
-- attributes only — display figures are client-built (SOP §3.5).
function ShelfRoomBuilder.NotifyShelfChanged(ownerUserId: number, slots: { [string]: string? })
	local station = stationForOwner(ownerUserId)
	if station ~= nil and type(slots) == "table" then
		reconcilePads(station, slots)
	end
end

function ShelfRoomBuilder.GetRoomForOwner(userId: number): Model?
	local station = stationForOwner(userId)
	return if station ~= nil then station.model else nil
end

function ShelfRoomBuilder.GetDoorIndexForOwner(userId: number): number?
	local station = stationForOwner(userId)
	return if station ~= nil then station.index else nil
end

function ShelfRoomBuilder.GetSlotPads(userId: number): { [string]: BasePart }?
	local station = stationForOwner(userId)
	return if station ~= nil then station.pads else nil
end

function ShelfRoomBuilder.IsCorridorActivated(): boolean
	return started
end

--------------------------------------------------------------------------------
-- Loader lifecycle
--------------------------------------------------------------------------------

function ShelfRoomBuilder:Init()
	-- HubService:Init (alphabetically earlier) has already laid the street;
	-- grab the lot anchors now so Start never races a missing hub.
	local hub = getSibling("HubService")
	local getter = if hub ~= nil then (hub.GetDisplayStationSlots or hub.GetShelfDoorSlots) else nil
	if type(getter) == "function" then
		local ok, slots = pcall(getter)
		if ok and type(slots) == "table" then
			for _, slot in slots do
				if type(slot) == "table" and type(slot.index) == "number" then
					stationSlots[slot.index] = slot
				end
			end
		end
	end
	if #stationSlots == 0 then
		warn("[ShelfRoomBuilder] no lot anchors from HubService — lots disabled")
	elseif #stationSlots ~= LOT_COUNT then
		warn(`[ShelfRoomBuilder] {#stationSlots} lot anchors (spec {LOT_COUNT})`)
	end
end

function ShelfRoomBuilder:Start()
	if started or #stationSlots == 0 then
		return
	end
	started = true

	-- Every lot starts in vacant dressing (SOP §1.2 — dressed, never bare).
	for index, slot in stationSlots do
		local station: LotState = {
			index = index,
			slot = slot,
			model = Instance.new("Model"), -- placeholder; replaced immediately
			owner = nil,
			ownerUserId = 0,
			tier = 0,
			generation = 0,
			pads = {},
			rings = {},
			signTitle = nil,
			signSubtitle = nil,
		}
		stations[index] = station
		rebuildVacant(station)
	end

	-- Occupancy of record: LobbyPlotService (connect first, then snapshot —
	-- setOccupant is idempotent, so the overlap is harmless).
	local plotService = getSibling("LobbyPlotService")
	local occupantSignal = if plotService ~= nil then plotService.OccupantChanged else nil
	if occupantSignal ~= nil and type(occupantSignal.Connect) == "function" then
		occupantSignal:Connect(function(index: number, player: Player?)
			setOccupant(index, player)
		end)
		if type(plotService.GetOccupancy) == "function" then
			local ok, occupancy = pcall(plotService.GetOccupancy)
			if ok and type(occupancy) == "table" then
				for index, player in occupancy :: { [number]: Player } do
					setOccupant(index, player)
				end
			end
		end
	else
		-- Test places without the plot service: join-order assignment.
		warn("[ShelfRoomBuilder] LobbyPlotService missing — join-order fallback assignment")
		Players.PlayerRemoving:Connect(fallbackRemove)
		Players.PlayerAdded:Connect(fallbackAdd)
		for _, player in Players:GetPlayers() do
			fallbackAdd(player)
		end
	end

	-- Safety-net reconciler: converge pad attrs with profile.shelf.slots and
	-- pick up housing-tier upgrades by replacing the whole lot Model.
	task.spawn(function()
		while true do
			task.wait(RECONCILE_SECONDS)
			for _, station in stations do
				local owner = station.owner
				if owner ~= nil and owner.Parent == Players and station.tier >= 0 then
					if housingTierOf(owner) ~= station.tier then
						station.generation += 1
						rebuildOwned(station, owner, housingTierOf(owner))
					else
						reconcilePadsFromProfile(station)
					end
				end
			end
		end
	end)
end

return ShelfRoomBuilder
