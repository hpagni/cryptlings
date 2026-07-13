--!strict
-- CRYPTLINGS: NIGHT SHIFT — ConsumableService (Stage 6 "Monetization wiring";
-- SOP §4.1 launch scope, §4.2 effects; module consumables-gameplay).
-- Server side of the Consumable.Use remote: validates ownership
-- (profile.consumables[kind] > 0) and context, applies the effect, decrements
-- inside PlayerDataService.Update (under WithLock — no double-spend), replies
-- {ok, remaining, err?} and tracks consumable_use{kind} (contract §H).
--
-- Effects (§4.2 Price Ladder of Record):
--   scentSpray   — "STEADY GRIPS" (playtest rework; internal key/sku keep the
--                  old name): for the CURRENT run only, carrying cases does
--                  NOT slow you ("CarrySpeedExempt" attribute, read by both
--                  WalkSpeed owners). Reset on shift Complete / death. Armed
--                  in the hub, it rides into the player's next run and
--                  expires when THAT run ends.
--   reviveBeacon — usable only while DOWNED: instant self-revive, restoring the
--                  player exactly as a completed teammate revive does
--                  (un-PlatformStand, un-anchor, health/walkspeed back,
--                  PlayerDownedState{downed=false}).
--   foremansKey  — usable within VAULT_KEY_RANGE_STUDS of the floor's tagged
--                  "VaultDoor": slides the door open (tween) and spawns 1 Tier3
--                  case at the "VaultCaseSpawn" anchor (FloorGen left both),
--                  following CaseService's case-Model conventions (greybox box,
--                  tier-color stripe, tag "Case" + caseUid attribute).
--
-- Client counterpart: ConsumableHUD. Owned-count seeding hack (documented,
-- kept inside these two files): on profile load — and again on the client's
-- "client_spawn_ready" funnel ping, which guarantees the HUD is connected —
-- this service pushes a synthetic ShopGrant {sku = "_SYNC", summary = JSON
-- {scentSpray, reviveBeacon, foremansKey}}. After that the client tracks
-- counts from real ShopGrant pushes and Consumable.Use replies.
--
-- Optional siblings consumed via pcall (degrade gracefully when absent):
--   NoiseService.SetPlayerCaseMult(player, mult) — contract §I (spray)
--   ShiftService.GetState/GetShiftId/GetFloorRoot/IsParticipant/IsDowned
--     (+ R2 additive GetFloorRootFor/GetShiftIdFor, preferred when present —
--     Lobby SOP Addendum 1 Change 6.5 / WP4.3: foremansKey/exitWarp floor
--     lookups are scoped to the PLAYER's own session so concurrent floors
--     never cross-talk; revive beacon unchanged, the facade routes it)
--   CaseService.ApplyCarrySpeed(player) — carry-weighted WalkSpeed on revive
--   AnalyticsService.Track / PlayerDataService.Get/Update/WithLock/IsLoaded
-- Forward-compatible feature detection (no edits needed here if added later):
--   ShiftService.RevivePlayer/ReviveDowned/RestoreDowned(player) -> boolean
--     — preferred beacon path (cancels the internal bleedout timer)
--   CaseService.SpawnCaseAt/SpawnExternalCase/RegisterExternalCase(tier, pos)
--     — preferred vault-case path (registers the case for pickup/banking)

local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConstants = require(Shared:WaitForChild("Config"):WaitForChild("GameConstants"))
local Remotes = require(Shared:WaitForChild("Net"):WaitForChild("Remotes"))
local Types = require(Shared:WaitForChild("Types"))

--------------------------------------------------------------------------------
-- Tuning — gameplay-facing values promoted to GameConstants at Stage 6
-- integration (§G; the key range is mirrored by ConsumableHUD's pulse range);
-- the rest is service-internal cadence.
--------------------------------------------------------------------------------

local VAULT_KEY_RANGE_STUDS = GameConstants.VAULT_KEY_RANGE_STUDS -- shared with ConsumableHUD
local VAULT_DOOR_OPEN_SECONDS = GameConstants.VAULT_DOOR_OPEN_SECONDS
local VAULT_CASE_TIER = GameConstants.VAULT_CASE_TIER -- the key's bonus case (§4.2)
local SPRAY_WATCH_POLL_SECONDS = 0.5 -- run-boundary watcher cadence
local PROFILE_SYNC_TIMEOUT_SECONDS = 60 -- give up pushing _SYNC after this
local PROFILE_SYNC_POLL_SECONDS = 0.25

-- CollectionService tags shared with FloorGenService (vault room) and the
-- client InputController (case targeting).
local TAG_VAULT_DOOR = "VaultDoor"
local TAG_VAULT_CASE_SPAWN = "VaultCaseSpawn"
local TAG_CASE = "Case"
local TAG_EXTRACTION_DOCK = "ExtractionDock" -- exitWarp destination (R2: scoped per session)
local ATTR_CASE_UID = "caseUid"

-- Synthetic ShopGrant sku used ONLY by the ConsumableHUD seeding hack.
local SYNC_SKU = "_SYNC"

-- Greybox case conventions mirrored from CaseService (fallback spawn path only;
-- the feature-detected CaseService spawn API is preferred when present).
local CASE_BODY_SIZE = Vector3.new(2.4, 1.6, 1.6)
local CASE_STRIPE_SIZE = Vector3.new(2.5, 0.35, 1.7)
local CASE_BODY_COLOR = Color3.fromRGB(148, 126, 100) -- greybox cardboard
local TIER3_STRIPE_COLOR = Color3.fromRGB(235, 190, 52) -- vault gold (§E Godly)

local VALID_KINDS: { [string]: boolean } = {
	scentSpray = true,
	reviveBeacon = true,
	foremansKey = true,
	exitWarp = true,
}

--------------------------------------------------------------------------------
-- Lazy sibling resolution (house pattern; missing modules degrade gracefully)
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

-- First sibling method from `names` that exists; called pcall-safe by users.
local function findMethod(service: any, names: { string }): ((...any) -> any)?
	if service == nil then
		return nil
	end
	for _, name in names do
		if type(service[name]) == "function" then
			return service[name]
		end
	end
	return nil
end

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local ConsumableService = {}

local sprayActive: { [Player]: boolean } = {} -- mult is 0 for this player
local sprayRunShiftId: { [Player]: string } = {} -- shiftId the spray is riding
local keyUsedShiftId: { [Player]: string } = {} -- one key per player per shift
local useBusy: { [Player]: boolean } = {} -- per-player invoke debounce
local syncedOnLoad: { [Player]: boolean } = {}
local lastSyncPushAt: { [Player]: number } = {} -- client_spawn_ready spam throttle

-- Exploiters can fire FunnelClient at any rate; without this floor the _SYNC
-- push (JSONEncode + FireClient) becomes a free amplification primitive.
local SYNC_PUSH_MIN_INTERVAL_SECONDS = 5

local shopGrantRemote: RemoteEvent? = nil
local downedStateRemote: RemoteEvent? = nil

local warnedBeaconFallback = false
local warnedCaseFallback = false

--------------------------------------------------------------------------------
-- Profile helpers
--------------------------------------------------------------------------------

local function getCount(player: Player, kind: string): number?
	local dataService = getSibling("PlayerDataService")
	if dataService == nil or type(dataService.Get) ~= "function" then
		return nil
	end
	local data = dataService.Get(player) :: Types.ProfileData?
	if data == nil or type(data.consumables) ~= "table" then
		return nil
	end
	local count = (data.consumables :: any)[kind]
	return if type(count) == "number" then count else 0
end

-- Pushes the synthetic ShopGrant the ConsumableHUD seeds its counts from.
local function pushSync(player: Player)
	if shopGrantRemote == nil or player.Parent == nil then
		return
	end
	local dataService = getSibling("PlayerDataService")
	if dataService == nil or type(dataService.Get) ~= "function" then
		return
	end
	local data = dataService.Get(player) :: Types.ProfileData?
	if data == nil or type(data.consumables) ~= "table" then
		return
	end
	local ok, summary = pcall(function()
		return HttpService:JSONEncode({
			scentSpray = data.consumables.scentSpray or 0,
			reviveBeacon = data.consumables.reviveBeacon or 0,
			foremansKey = data.consumables.foremansKey or 0,
		})
	end)
	if ok then
		shopGrantRemote:FireClient(player, { sku = SYNC_SKU, summary = summary })
	end
end

--------------------------------------------------------------------------------
-- Scent spray (§4.2: "Scent-mask spray (1 run)")
--------------------------------------------------------------------------------

-- Steady Grips effect (replaced the old silent-case spray per playtest
-- direction): the "CarrySpeedExempt" attribute removes the carry slowdown.
-- Both WalkSpeed owners (server CaseService.ApplyCarrySpeed, client
-- InputController.applyWalkSpeed) read the attribute, so they stay agreed.
local function setCarryExempt(player: Player, exempt: boolean)
	player:SetAttribute("CarrySpeedExempt", if exempt then true else nil)
	local cases = getSibling("CaseService")
	if cases ~= nil and type(cases.ApplyCarrySpeed) == "function" then
		pcall(cases.ApplyCarrySpeed, player)
	end
end

local function clearSpray(player: Player)
	if sprayActive[player] then
		sprayActive[player] = nil
		sprayRunShiftId[player] = nil
		if player.Parent ~= nil then
			setCarryExempt(player, false)
		end
	end
end

local function applyScentSpray(player: Player): (boolean, string?)
	if sprayActive[player] then
		return false, "ALREADY_ACTIVE"
	end
	local shift = getSibling("ShiftService")
	if shift ~= nil and type(shift.GetState) == "function" then
		local ok, state = pcall(shift.GetState)
		if ok and state == "Complete" then
			return false, "WRONG_CONTEXT" -- between runs; arm it in the intermission
		end
	end

	setCarryExempt(player, true)
	sprayActive[player] = true

	-- Used mid-run: the spray is already riding the current shift. Used in the
	-- hub/intermission: the watcher stamps the shiftId once they clock in.
	if shift ~= nil and type(shift.IsActive) == "function" and type(shift.IsParticipant) == "function" then
		local okActive, active = pcall(shift.IsActive)
		local okPart, participant = pcall(shift.IsParticipant, player)
		if okActive and active == true and okPart and participant == true and type(shift.GetShiftId) == "function" then
			local okId, shiftId = pcall(shift.GetShiftId)
			if okId and type(shiftId) == "string" then
				sprayRunShiftId[player] = shiftId
			end
		end
	end
	return true, nil
end

-- "1 run" enforcement: a spray that rode shift X resets the moment the loop
-- leaves X (Complete, or a new shift the player isn't sprayed for). Death is
-- handled by the per-character Died hook below.
local function sprayWatchTick()
	local shift = getSibling("ShiftService")
	if shift == nil or type(shift.GetState) ~= "function" then
		return
	end
	local okState, state = pcall(shift.GetState)
	if not okState then
		return
	end
	local shiftId: string? = nil
	if type(shift.GetShiftId) == "function" then
		local okId, id = pcall(shift.GetShiftId)
		if okId and type(id) == "string" then
			shiftId = id
		end
	end

	local toClear: { Player } = {}
	if state == "Active" and shiftId ~= nil then
		for player in sprayActive do
			if sprayRunShiftId[player] == nil and type(shift.IsParticipant) == "function" then
				local ok, participant = pcall(shift.IsParticipant, player)
				if ok and participant == true then
					sprayRunShiftId[player] = shiftId
				end
			end
		end
		for player, ranId in sprayRunShiftId do
			if ranId ~= shiftId then
				table.insert(toClear, player) -- a different run started without them
			end
		end
	else
		-- Not Active (Complete or Intermission): every spray that rode a run is spent.
		for player in sprayRunShiftId do
			table.insert(toClear, player)
		end
	end
	for _, player in toClear do
		clearSpray(player)
	end
end

--------------------------------------------------------------------------------
-- Revive beacon (§4.2: instant self-revive while DOWNED)
--------------------------------------------------------------------------------

local function applyReviveBeacon(player: Player): (boolean, string?)
	local shift = getSibling("ShiftService")
	if shift == nil or type(shift.IsDowned) ~= "function" then
		return false, "WRONG_CONTEXT"
	end
	local okDowned, downed = pcall(shift.IsDowned, player)
	if not okDowned or downed ~= true then
		return false, "NOT_DOWNED"
	end

	-- Preferred path: a public ShiftService revive (cancels the internal
	-- bleedout timer exactly like a teammate revive). Feature-detected so this
	-- file needs no edit when the integrator adds it.
	local revive = findMethod(shift, { "RevivePlayer", "ReviveDowned", "RestoreDowned", "SelfRevive" })
	if revive ~= nil then
		local ok, result = pcall(revive, player)
		if ok and result ~= false then
			track(player, "revived", { byUserId = player.UserId })
			return true, nil
		end
		return false, "FAILED"
	end

	-- Fallback: restore against the observable contract of a completed revive
	-- (un-PlatformStand, un-anchor, health/walkspeed back, downed=false push).
	-- KNOWN GAP (open issue for the integrator): ShiftService's private bleedout
	-- timer keeps ticking — the player still dies at the 45s mark.
	if not warnedBeaconFallback then
		warnedBeaconFallback = true
		warn(
			"[ConsumableService] ShiftService has no public revive — beacon uses the observable-contract fallback"
				.. " (internal bleedout timer NOT cancelled; see Stage 6 open issues)"
		)
	end

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if character == nil or humanoid == nil or humanoid.Health <= 0 then
		return false, "FAILED"
	end
	if root ~= nil and root:IsA("BasePart") then
		root.Anchored = false
	end
	humanoid.PlatformStand = false
	humanoid.Health = humanoid.MaxHealth
	local caseService = getSibling("CaseService")
	if caseService ~= nil and type(caseService.ApplyCarrySpeed) == "function" then
		pcall(caseService.ApplyCarrySpeed, player)
	else
		humanoid.WalkSpeed = GameConstants.WALKSPEED_BASE
	end
	if downedStateRemote ~= nil then
		-- R2 contract: PlayerDownedState is delivered per-session-roster only,
		-- never FireAllClients (cross-session bleedout-ring leak). Fallback
		-- recipient set is the player alone when no session resolves.
		local payload = { userId = player.UserId, downed = false }
		local session = nil
		if shift ~= nil and type(shift.GetSessionOf) == "function" then
			local ok, result = pcall(shift.GetSessionOf, player)
			if ok then
				session = result
			end
		end
		if session ~= nil and type(session.participants) == "table" then
			for member in session.participants do
				if typeof(member) == "Instance" and member.Parent == Players then
					downedStateRemote:FireClient(member, payload)
				end
			end
		else
			downedStateRemote:FireClient(player, payload)
		end
	end
	track(player, "revived", { byUserId = player.UserId })
	return true, nil
end

--------------------------------------------------------------------------------
-- Foreman's Key (§4.2: "1 bonus vault case")
--------------------------------------------------------------------------------

-- R2 (WP4.3): the PLAYER's own session floor via the additive facade API
-- (GetFloorRootFor); when GetFloorRootFor exists its answer is authoritative
-- (nil = no session floor for this player). The legacy global GetFloorRoot
-- read survives only when the facade lacks the additive API (house rule:
-- degrade to today's global behavior).
local function getPlayerFloorRoot(player: Player): Instance?
	local shift = getSibling("ShiftService")
	if shift == nil then
		return nil
	end
	if type(shift.GetFloorRootFor) == "function" then
		local ok, floorRoot = pcall(shift.GetFloorRootFor, player)
		if ok then
			return if typeof(floorRoot) == "Instance" then floorRoot else nil
		end
	end
	if type(shift.GetFloorRoot) == "function" then
		local ok, floorRoot = pcall(shift.GetFloorRoot)
		if ok and typeof(floorRoot) == "Instance" then
			return floorRoot
		end
	end
	return nil
end

local function findTaggedInFloor(player: Player, tag: string): BasePart?
	local floorRoot = getPlayerFloorRoot(player)
	if floorRoot == nil then
		return nil
	end
	for _, instance in CollectionService:GetTagged(tag) do
		if instance:IsA("BasePart") and instance:IsDescendantOf(floorRoot) then
			return instance
		end
	end
	return nil
end

-- Slides the vault door down into the floor (greybox tween; CanCollide drops
-- immediately so the buyer is never blocked by tween latency).
local function openVaultDoor(door: BasePart)
	door.CanCollide = false
	local tween = TweenService:Create(
		door,
		TweenInfo.new(VAULT_DOOR_OPEN_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
		{ CFrame = door.CFrame - Vector3.new(0, math.max(door.Size.Y - 0.3, 0), 0) }
	)
	tween:Play()
end

-- Fallback greybox Tier3 case matching CaseService's model conventions (tag
-- "Case" + caseUid/CaseUid/CaseTier attributes, body + tier-color stripe).
-- Parented under the floor model so shift teardown cleans it up.
local function buildFallbackVaultCase(position: Vector3, parent: Instance): Model
	local uid = HttpService:GenerateGUID(false)

	local model = Instance.new("Model")
	model.Name = "Case"
	model:SetAttribute("CaseUid", uid)
	model:SetAttribute("CaseTier", VAULT_CASE_TIER)
	model:SetAttribute(ATTR_CASE_UID, uid)
	CollectionService:AddTag(model, TAG_CASE)

	local baseCFrame = CFrame.new(position)

	local body = Instance.new("Part")
	body.Name = "Body"
	body.Size = CASE_BODY_SIZE
	body.CFrame = baseCFrame
	body.Anchored = true
	body.Color = CASE_BODY_COLOR
	body.TopSurface = Enum.SurfaceType.Smooth
	body.BottomSurface = Enum.SurfaceType.Smooth
	body.Parent = model

	local stripe = Instance.new("Part")
	stripe.Name = "Stripe"
	stripe.Size = CASE_STRIPE_SIZE
	stripe.CFrame = baseCFrame * CFrame.new(0, 0.45, 0)
	stripe.Anchored = false
	stripe.CanCollide = false
	stripe.Massless = true
	stripe.Color = TIER3_STRIPE_COLOR
	stripe.TopSurface = Enum.SurfaceType.Smooth
	stripe.BottomSurface = Enum.SurfaceType.Smooth
	stripe.Parent = model

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = body
	weld.Part1 = stripe
	weld.Parent = stripe

	model.PrimaryPart = body
	model.Parent = parent
	return model
end

local function spawnVaultCase(player: Player, position: Vector3): boolean
	-- Preferred path: CaseService registers the case itself so RequestPickupCase
	-- / TakeAllCarried (banking) work natively. Feature-detected (see header).
	local caseService = getSibling("CaseService")
	local spawnCase =
		findMethod(caseService, { "SpawnCaseAt", "SpawnExternalCase", "RegisterExternalCase", "SpawnSingleCase" })
	if spawnCase ~= nil then
		local ok, result = pcall(spawnCase, VAULT_CASE_TIER, position)
		if ok and result ~= nil and result ~= false then
			return true
		end
	end

	-- Fallback: build the case to convention ourselves. KNOWN GAP (open issue):
	-- CaseService.onRequestPickup resolves uids against its private registry,
	-- so this case is visible/targetable but not yet carryable until CaseService
	-- exposes a registration path.
	if not warnedCaseFallback then
		warnedCaseFallback = true
		warn(
			"[ConsumableService] CaseService has no external spawn API — vault case built to convention"
				.. " but unregistered (pickup will NOT_FOUND; see Stage 6 open issues)"
		)
	end
	-- R2 (WP4.3): parent under the BUYER's session floor (GetFloorRootFor
	-- preferred via getPlayerFloorRoot) so that session's teardown — and only
	-- that session's — cleans the case up.
	local floorRoot = getPlayerFloorRoot(player)
	local parent: Instance = if floorRoot ~= nil then floorRoot else Workspace
	buildFallbackVaultCase(position, parent)
	return true
end

local function applyForemansKey(player: Player): (boolean, string?)
	local shift = getSibling("ShiftService")
	if shift == nil or type(shift.IsActive) ~= "function" then
		return false, "WRONG_CONTEXT"
	end
	local okActive, active = pcall(shift.IsActive)
	if not okActive or active ~= true then
		return false, "WRONG_CONTEXT"
	end
	if type(shift.IsDowned) == "function" then
		local ok, downed = pcall(shift.IsDowned, player)
		if ok and downed == true then
			return false, "WRONG_CONTEXT"
		end
	end

	-- R2 (WP4.3): dedupe against THEIR session's shift id (GetShiftIdFor,
	-- feature-detected); the global single-session read stays as the fallback.
	local shiftId: string? = nil
	if type(shift.GetShiftIdFor) == "function" then
		local ok, id = pcall(shift.GetShiftIdFor, player)
		if ok and type(id) == "string" then
			shiftId = id
		end
	elseif type(shift.GetShiftId) == "function" then
		local ok, id = pcall(shift.GetShiftId)
		if ok and type(id) == "string" then
			shiftId = id
		end
	end
	if shiftId ~= nil and keyUsedShiftId[player] == shiftId then
		return false, "ALREADY_USED" -- one bonus vault case per player per shift
	end

	local door = findTaggedInFloor(player, TAG_VAULT_DOOR)
	if door == nil then
		return false, "NO_VAULT"
	end

	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root == nil or not root:IsA("BasePart") then
		return false, "FAILED"
	end
	if (root.Position - door.Position).Magnitude > VAULT_KEY_RANGE_STUDS then
		return false, "TOO_FAR"
	end

	-- Door opens once per floor (CanCollide doubles as the "still locked"
	-- marker — each shift generates a fresh door); every key spawns its own
	-- Tier3 case.
	if door.CanCollide then
		openVaultDoor(door)
	end

	local anchor = findTaggedInFloor(player, TAG_VAULT_CASE_SPAWN)
	local spawnPosition: Vector3
	if anchor ~= nil then
		spawnPosition = anchor.Position
	else
		-- Degenerate floor (greybox fallback without a vault room marker):
		-- drop the case just past the door so the purchase still pays out.
		spawnPosition = door.Position + Vector3.new(0, 1.5, 0)
	end
	if not spawnVaultCase(player, spawnPosition) then
		return false, "FAILED"
	end

	if shiftId ~= nil then
		keyUsedShiftId[player] = shiftId
	end
	return true, nil
end

--------------------------------------------------------------------------------
-- Consumable.Use handler
--------------------------------------------------------------------------------

-- exitWarp (EXIT_WARP product): teleport the user to the extraction dock.
-- Usable only mid-run (Active shift, participant, not downed) — in the hub
-- there is nothing to escape from, and the item must never burn there.
local function applyExitWarp(player: Player): (boolean, string?)
	local shift = getSibling("ShiftService")
	if shift == nil then
		return false, "NO_SHIFT"
	end
	local stateOk, state = pcall(shift.GetState)
	if not stateOk or state ~= "Active" then
		return false, "NOT_ACTIVE"
	end
	if type(shift.IsParticipant) == "function" then
		local ok, participant = pcall(shift.IsParticipant, player)
		if not ok or participant ~= true then
			return false, "NOT_PARTICIPANT"
		end
	end
	if type(shift.IsDowned) == "function" then
		local ok, downed = pcall(shift.IsDowned, player)
		if ok and downed == true then
			return false, "DOWNED"
		end
	end
	-- R2 (WP4.3): warp to the PLAYER's OWN session dock — the tagged
	-- ExtractionDock under their floor root — never a concurrent neighbor
	-- floor's. The FloorGen single-floor shim stays as the legacy fallback.
	local zone: BasePart? = findTaggedInFloor(player, TAG_EXTRACTION_DOCK)
	if zone == nil then
		local floorGen = getSibling("FloorGenService")
		if floorGen ~= nil and type(floorGen.GetExtractZone) == "function" then
			local zoneOk, legacyZone = pcall(floorGen.GetExtractZone)
			if zoneOk and typeof(legacyZone) == "Instance" and legacyZone:IsA("BasePart") then
				zone = legacyZone
			end
		end
	end
	if zone == nil then
		return false, "NO_EXIT"
	end
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root == nil or not root:IsA("BasePart") then
		return false, "NO_CHARACTER"
	end
	root.CFrame = zone.CFrame + Vector3.new(0, 4, 0)
	-- Re-seed ShiftService's movement validator (feature-detected, same thread —
	-- no yield between the CFrame write and this call): without it the
	-- anti-teleport snapback reverts the legit warp on its next 1s tick.
	local note = findMethod(shift, { "NoteServerTeleport", "ForgiveTeleport" })
	if note ~= nil then
		pcall(note, player)
	end
	return true, nil
end

local EFFECTS: { [string]: (Player) -> (boolean, string?) } = {
	scentSpray = applyScentSpray,
	reviveBeacon = applyReviveBeacon,
	foremansKey = applyForemansKey,
	exitWarp = applyExitWarp,
}

local function onUse(player: Player, kind: any): { [string]: any }
	if type(kind) ~= "string" or not VALID_KINDS[kind] then
		return { ok = false, remaining = 0, err = "BAD_ARG" }
	end

	local dataService = getSibling("PlayerDataService")
	if
		dataService == nil
		or type(dataService.IsLoaded) ~= "function"
		or type(dataService.WithLock) ~= "function"
		or type(dataService.Update) ~= "function"
		or not dataService.IsLoaded(player)
	then
		return { ok = false, remaining = 0, err = "NOT_LOADED" }
	end

	if useBusy[player] then
		return { ok = false, remaining = getCount(player, kind) or 0, err = "BUSY" }
	end
	useBusy[player] = true

	-- WithLock: ownership check -> effect -> decrement is atomic against the
	-- monetization grant path (same per-player mutex; contract §D).
	local okLock, reply = dataService.WithLock(player, function()
		local count = getCount(player, kind) or 0
		if count < 1 then
			return { ok = false, remaining = 0, err = "NONE_OWNED" }
		end

		-- Effect first: a failed context (not downed, too far from the vault,
		-- spray already active, ...) must never burn the item.
		local effectOk, effectErr = EFFECTS[kind](player)
		if not effectOk then
			return { ok = false, remaining = count, err = effectErr or "FAILED" }
		end

		local remaining = count - 1
		local updated = dataService.Update(player, function(data: Types.ProfileData)
			local owned = (data.consumables :: any)[kind]
			local newCount = math.max((if type(owned) == "number" then owned else 0) - 1, 0);
			(data.consumables :: any)[kind] = newCount
			remaining = newCount
		end)
		if not updated then
			-- Effect already granted; the write failing is a server-side fault
			-- worth a log, never a reason to claw back the effect.
			warn(`[ConsumableService] decrement failed for {player.Name} ({kind}) after effect applied`)
		end

		track(player, "consumable_use", { kind = kind })
		return { ok = true, remaining = remaining }
	end)

	useBusy[player] = nil

	if okLock and type(reply) == "table" then
		return reply
	end
	return { ok = false, remaining = getCount(player, kind) or 0, err = "FAILED" }
end

--------------------------------------------------------------------------------
-- Player wiring
--------------------------------------------------------------------------------

local function onCharacterAdded(player: Player, character: Model)
	local humanoid = character:WaitForChild("Humanoid", 10)
	if humanoid == nil or not humanoid:IsA("Humanoid") then
		return
	end
	humanoid.Died:Connect(function()
		clearSpray(player) -- §4.2 "1 run": death ends the run, the spray goes with it
	end)
end

local function onPlayerAdded(player: Player)
	player.CharacterAdded:Connect(function(character)
		task.spawn(onCharacterAdded, player, character)
	end)
	if player.Character ~= nil then
		task.spawn(onCharacterAdded, player, player.Character)
	end

	-- Seed the ConsumableHUD once the profile session-locks.
	task.spawn(function()
		local dataService = getSibling("PlayerDataService")
		if dataService == nil or type(dataService.IsLoaded) ~= "function" then
			return
		end
		local deadline = os.clock() + PROFILE_SYNC_TIMEOUT_SECONDS
		while player.Parent ~= nil and os.clock() < deadline do
			if dataService.IsLoaded(player) then
				syncedOnLoad[player] = true
				pushSync(player)
				return
			end
			task.wait(PROFILE_SYNC_POLL_SECONDS)
		end
	end)
end

local function onPlayerRemoving(player: Player)
	sprayActive[player] = nil
	sprayRunShiftId[player] = nil
	keyUsedShiftId[player] = nil
	useBusy[player] = nil
	syncedOnLoad[player] = nil
	lastSyncPushAt[player] = nil
	-- NoiseService resets its per-player mult on leave; nothing to undo there.
end

--------------------------------------------------------------------------------
-- Loader lifecycle
--------------------------------------------------------------------------------

function ConsumableService:Init()
	-- Remotes exist before any service Init (init.server contract). No yields.
	local ok, err = pcall(function()
		shopGrantRemote = Remotes.GetEvent("ShopGrant")
		downedStateRemote = Remotes.GetEvent("PlayerDownedState")
		Remotes.GetFunction("Consumable.Use").OnServerInvoke = function(player: Player, kind: any)
			return onUse(player, kind)
		end
		-- Second _SYNC trigger: client_spawn_ready proves the ConsumableHUD is
		-- connected (the on-load push can race the client's remote hookup).
		-- Listening is additive — AnalyticsService keeps its own connection.
		Remotes.GetEvent("FunnelClient").OnServerEvent:Connect(function(player: Player, payload: any)
			if type(payload) == "table" and payload.event == "client_spawn_ready" and syncedOnLoad[player] then
				local clock = os.clock()
				local lastAt = lastSyncPushAt[player]
				if lastAt ~= nil and clock - lastAt < SYNC_PUSH_MIN_INTERVAL_SECONDS then
					return -- rate-limited: hostile clients can spam this remote
				end
				lastSyncPushAt[player] = clock
				pushSync(player)
			end
		end)
	end)
	if not ok then
		warn(`[ConsumableService] remote bind failed: {err}`)
	end

	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
end

function ConsumableService:Start()
	-- Run-boundary watcher: enforces the spray's "current run only" lifetime.
	while true do
		task.wait(SPRAY_WATCH_POLL_SECONDS)
		local ok, err = pcall(sprayWatchTick)
		if not ok then
			warn(`[ConsumableService] spray watcher tick failed: {err}`)
		end
	end
end

return ConsumableService
