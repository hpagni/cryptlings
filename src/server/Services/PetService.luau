--!strict
-- CRYPTLINGS: NIGHT SHIFT — PetService (equippable pets).
-- Server-authoritative follower pet: equip ONE owned cryptling
-- (profile.collection[id] > 0) and a small greybox copy of it — built from
-- RarityTable.GetCryptling(id).recipe, THE render spec, at PET_SCALE — follows
-- the player in-world. Parts are anchored + CanCollide/CanQuery/CanTouch false
-- (never a Defect raycast/path obstacle, contract: pets cannot interfere with
-- the run) and repositioned via PivotTo on Heartbeat to an exponentially
-- smoothed point behind-right of the character root with a small hover bob.
-- The pet despawns while its owner is downed (ShiftService.IsDowned), on
-- death (rebuilt on the next Heartbeat after respawn), on unequip, and on
-- leave.
--
-- Persistence (contract §D, reconcile-safe addition):
--   profile.pets = { equippedId = "" (none), upgradeLevel = 0 (cap
--   PET_UPGRADE_MAX_LEVEL via the 249 R$ PET_TREATS dev product) }
--
-- Remotes (manifest of record: Shared.Net.Remotes — payloads documented there):
--   Pet.Equip(cryptlingId | "") -> {ok, err?}   Pet.GetState() -> state
--
-- Perks (rarity-scaled, GameConstants.PET_PERKS; math in Shared.Logic.PetPerks
-- so PetUI displays exactly what is applied):
--   * maxHealth — the SHIPPED perk. Applied to Humanoid.MaxHealth/Health on
--     CharacterAdded and on every equip/upgrade change; the applied amount is
--     tracked in the humanoid attribute "PetHealthApplied" so respawns
--     self-reset and re-applies are exact diffs. Nothing else in the codebase
--     writes MaxHealth, so this is conflict-free.
--   * speedBonus / pvpStrength / carryBonus — published as the player
--     attributes "PetSpeedBonus" / "PetPvpStrength" / "PetCarryBonus" and
--     consumed by their owners: both WalkSpeed owners (client
--     InputController.applyWalkSpeed and server CaseService.ApplyCarrySpeed) add
--     the speed bonus; CombatService scales outgoing PVP damage by
--     1 + pvpStrength; CaseService.GetMaxCarry adds floor(carryBonus) slots.
--   * WHICH dimensions a pet grants is set by its perk kind
--     (PetPerks.PERK_KIND_BY_ID); inactive dimensions resolve to 0.
--
-- Monetization wiring (PET_TREATS, grants = {petUpgrade = true}):
--   PetService.GrantUpgrade(player) -> boolean — called by MonetizationService
--   inside the receipt lock (same contract as LockerService.ResetOpenAllowance:
--   non-yielding, false only when the profile is unavailable). At the cap it
--   still returns true and grants nothing extra (PetUI hides UPGRADE at cap;
--   a raced receipt is consumed, mirroring the STARTER_PACK precedent).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConstants = require(Shared:WaitForChild("Config"):WaitForChild("GameConstants"))
local RarityTable = require(Shared:WaitForChild("Config"):WaitForChild("RarityTable"))
local PetPerks = require(Shared:WaitForChild("Logic"):WaitForChild("PetPerks"))
local Remotes = require(Shared:WaitForChild("Net"):WaitForChild("Remotes"))
local Types = require(Shared:WaitForChild("Types"))

--------------------------------------------------------------------------------
-- Tuning (all gameplay numbers live in GameConstants §G)
--------------------------------------------------------------------------------

local PET_SCALE = GameConstants.PET_SCALE
local FOLLOW_RIGHT = GameConstants.PET_FOLLOW_RIGHT_STUDS
local FOLLOW_BACK = GameConstants.PET_FOLLOW_BACK_STUDS
local RESPONSIVENESS = GameConstants.PET_FOLLOW_RESPONSIVENESS
local TELEPORT_DISTANCE = GameConstants.PET_TELEPORT_DISTANCE_STUDS
local BOB_AMPLITUDE = GameConstants.PET_BOB_AMPLITUDE_STUDS
local BOB_CYCLES = GameConstants.PET_BOB_CYCLES_PER_SECOND

local PETS_FOLDER_NAME = "Pets"
local ATTR_HEALTH_APPLIED = "PetHealthApplied" -- on the Humanoid (dies with it)
local ATTR_SPEED_BONUS = "PetSpeedBonus" -- on the Player (read by both WalkSpeed owners)
local ATTR_PVP_STRENGTH = "PetPvpStrength" -- on the Player (CombatService scales damage)
local ATTR_CARRY_BONUS = "PetCarryBonus" -- on the Player (CaseService.GetMaxCarry adds floor)

local PROFILE_WAIT_TIMEOUT_SECONDS = 60 -- join flow: wait for the session lock
local PROFILE_WAIT_POLL_SECONDS = 1

--------------------------------------------------------------------------------
-- Lazy sibling resolution (house pattern: a missing parallel-stage module
-- degrades that feature, never the rest)
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

local function getDataService(): any
	local dataService = getSibling("PlayerDataService")
	if
		dataService ~= nil
		and type(dataService.Get) == "function"
		and type(dataService.IsLoaded) == "function"
		and type(dataService.Update) == "function"
	then
		return dataService
	end
	return nil
end

local function isDowned(player: Player): boolean
	local shift = getSibling("ShiftService")
	if shift ~= nil and type(shift.IsDowned) == "function" then
		local ok, downed = pcall(shift.IsDowned, player)
		return ok and downed == true
	end
	return false
end

--------------------------------------------------------------------------------
-- Service + state
--------------------------------------------------------------------------------

local PetService = {}

type PetState = {
	equippedId: string,
	model: Model?,
	position: Vector3?, -- smoothed follow point (nil = snap on next frame)
	bobClock: number,
}

local petStates: { [Player]: PetState } = {}
local joinWired: { [Player]: boolean } = {}
local petsFolder: Folder? = nil

local function getState(player: Player): PetState
	local state = petStates[player]
	if state == nil then
		state = { equippedId = "", model = nil, position = nil, bobClock = 0 }
		petStates[player] = state
	end
	return state
end

local function getPetsFolder(): Folder
	if petsFolder ~= nil and petsFolder.Parent ~= nil then
		return petsFolder
	end
	local existing = Workspace:FindFirstChild(PETS_FOLDER_NAME)
	if existing ~= nil and existing:IsA("Folder") then
		petsFolder = existing
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = PETS_FOLDER_NAME
	folder.Parent = Workspace
	petsFolder = folder
	return folder
end

--------------------------------------------------------------------------------
-- Greybox pet model (recipe = THE render spec; same part conventions as the
-- shelf displays — anchored, fully non-physical so the Defect never sees it)
--------------------------------------------------------------------------------

local function makePetPart(parent: Instance, shape: string, size: Vector3, cframe: CFrame, color: Color3): BasePart
	local part: BasePart
	if shape == "Wedge" then
		part = Instance.new("WedgePart")
	else
		local p = Instance.new("Part")
		if shape == "Ball" then
			p.Shape = Enum.PartType.Ball
		elseif shape == "Cylinder" then
			p.Shape = Enum.PartType.Cylinder
		end
		part = p
	end
	part.Size = size
	part.CFrame = cframe
	part.Color = color
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Material = Enum.Material.SmoothPlastic
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

-- Builds the scaled greybox at the workspace origin (pivot = ground at Y=0,
-- matching the recipe convention); the Heartbeat PivotTo places it.
local function buildPetModel(player: Player, cryptlingId: string): Model?
	local def: any = RarityTable.GetCryptling(cryptlingId)
	if def == nil then
		return nil
	end
	local defScale = if type(def.scale) == "number" then def.scale else 1
	local scale = PET_SCALE * defScale

	local model = Instance.new("Model")
	model.Name = `Pet_{player.UserId}`
	for _, rp in def.recipe :: { any } do
		local offset = rp.offset :: CFrame
		local scaledOffset = CFrame.new(offset.Position * scale) * offset.Rotation
		makePetPart(
			model,
			rp.shape,
			(rp.size :: Vector3) * scale,
			scaledOffset,
			(rp.colorOverride :: Color3?) or (def.color :: Color3)
		)
	end
	model:SetAttribute("OwnerUserId", player.UserId)
	model:SetAttribute("CryptlingId", cryptlingId)
	model.WorldPivot = CFrame.new()
	model.Parent = getPetsFolder()
	return model
end

local function despawnModel(state: PetState)
	local model = state.model
	state.model = nil
	state.position = nil
	if model ~= nil then
		model:Destroy()
	end
end

--------------------------------------------------------------------------------
-- Perk application (see header: health shipped, speed advisory)
--------------------------------------------------------------------------------

-- Resolved perk for the player's CURRENT profile pet, or nil when unequipped /
-- unknown / profile not loaded.
local function currentPerk(player: any): PetPerks.Perk?
	local dataService = getDataService()
	if dataService == nil then
		return nil
	end
	local data = dataService.Get(player) :: Types.ProfileData?
	if data == nil or data.pets.equippedId == "" then
		return nil
	end
	local def: any = RarityTable.GetCryptling(data.pets.equippedId)
	if def == nil then
		return nil
	end
	return PetPerks.GetPerkForId(def.rarity, data.pets.upgradeLevel, def.id)
end

-- Applies the perk as an exact diff against what this humanoid already carries
-- (ATTR_HEALTH_APPLIED): idempotent, safe to call on equip, upgrade, and every
-- CharacterAdded (a fresh humanoid starts at attribute nil = 0 applied).
local function applyPerks(player: any)
	if typeof(player) ~= "Instance" then
		return -- ForTest player-like fixtures carry no character/attributes
	end
	local perk = currentPerk(player)

	-- Publish the advisory perk attributes the other WalkSpeed/combat/carry
	-- owners read (client InputController, CombatService, CaseService).
	pcall(function()
		player:SetAttribute(ATTR_SPEED_BONUS, if perk ~= nil then perk.speedBonus else 0)
		player:SetAttribute(ATTR_PVP_STRENGTH, if perk ~= nil then perk.pvpStrength else 0)
		player:SetAttribute(ATTR_CARRY_BONUS, if perk ~= nil then perk.carryBonus else 0)
	end)

	-- A speed/carry change must re-settle WalkSpeed now (CaseService owns the
	-- server side; the client mirrors via its own attribute listener).
	local caseService = getSibling("CaseService")
	if caseService ~= nil and type(caseService.ApplyCarrySpeed) == "function" then
		pcall(caseService.ApplyCarrySpeed, player)
	end

	local character = (player :: Player).Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil then
		return
	end
	local desired = if perk ~= nil then perk.maxHealth else 0
	local applied = tonumber(humanoid:GetAttribute(ATTR_HEALTH_APPLIED)) or 0
	local delta = desired - applied
	if delta == 0 then
		return
	end
	humanoid.MaxHealth += delta
	if delta > 0 then
		if humanoid.Health > 0 then
			humanoid.Health += delta -- the bonus arrives filled, never as a wound
		end
	else
		humanoid.Health = math.min(humanoid.Health, humanoid.MaxHealth)
	end
	humanoid:SetAttribute(ATTR_HEALTH_APPLIED, desired)
end

--------------------------------------------------------------------------------
-- Heartbeat follow loop
--------------------------------------------------------------------------------

local TAU = 2 * math.pi

local function updatePet(player: Player, state: PetState, dt: number)
	if state.equippedId == "" then
		if state.model ~= nil then
			despawnModel(state)
		end
		return
	end

	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if
		root == nil
		or not root:IsA("BasePart")
		or humanoid == nil
		or humanoid.Health <= 0 -- death: despawn now, rebuild after respawn
		or isDowned(player) -- contract: no pet while the owner is downed
	then
		if state.model ~= nil then
			despawnModel(state)
		end
		return
	end

	local model = state.model
	if model == nil or model.Parent == nil then
		model = buildPetModel(player, state.equippedId)
		if model == nil then
			state.equippedId = "" -- unknown id (line rotated?): stop retrying
			return
		end
		state.model = model
		state.position = nil -- snap to the fresh target
	end

	-- Follow point: behind-right of the root in yaw-only character space, on
	-- the ground plane under the root (recipes stand on their pivot).
	local rootCF = root.CFrame
	local _, yaw = rootCF:ToOrientation()
	local yawCF = CFrame.fromOrientation(0, yaw, 0)
	local footY = root.Position.Y - root.Size.Y / 2 - humanoid.HipHeight
	local planar = root.Position + yawCF.RightVector * FOLLOW_RIGHT - yawCF.LookVector * FOLLOW_BACK
	local target = Vector3.new(planar.X, footY, planar.Z)

	local current = state.position
	if current == nil or (current - target).Magnitude > TELEPORT_DISTANCE then
		current = target -- spawn/teleport snap: never lerp across the floor
	else
		current = current:Lerp(target, 1 - math.exp(-RESPONSIVENESS * dt))
	end
	state.position = current

	-- Hover bob rides on top of the smoothed point (offset up by the amplitude
	-- so the lowest point of the cycle still clears the ground).
	state.bobClock = (state.bobClock + dt) % (1 / BOB_CYCLES)
	local bob = BOB_AMPLITUDE + math.sin(state.bobClock * TAU * BOB_CYCLES) * BOB_AMPLITUDE
	local pivot = CFrame.new(current + Vector3.new(0, bob, 0)) * yawCF.Rotation
	model:PivotTo(pivot)
end

--------------------------------------------------------------------------------
-- Remote handlers
--------------------------------------------------------------------------------

local function onEquip(player: Player, cryptlingId: any): { ok: boolean, err: string? }
	if type(cryptlingId) ~= "string" then
		return { ok = false, err = "BAD_ARG" }
	end
	local dataService = getDataService()
	if dataService == nil or not dataService.IsLoaded(player) then
		return { ok = false, err = "NO_PROFILE" }
	end
	local data = dataService.Get(player) :: Types.ProfileData?
	if data == nil then
		return { ok = false, err = "NO_PROFILE" }
	end
	if cryptlingId ~= "" then
		if RarityTable.GetCryptling(cryptlingId) == nil then
			return { ok = false, err = "UNKNOWN_ID" }
		end
		if (data.collection[cryptlingId] or 0) <= 0 then
			return { ok = false, err = "NOT_OWNED" }
		end
	end

	local updated = dataService.Update(player, function(live: Types.ProfileData)
		live.pets.equippedId = cryptlingId
	end) == true
	if not updated then
		return { ok = false, err = "NO_PROFILE" }
	end

	local state = getState(player)
	state.equippedId = cryptlingId
	despawnModel(state) -- next Heartbeat rebuilds (or stays empty on unequip)
	applyPerks(player)
	return { ok = true }
end

local function onGetState(player: Player): { [string]: any }
	local payload: { [string]: any } = {
		equippedId = "",
		upgradeLevel = 0,
		ownedIds = {},
		perk = nil,
	}
	local dataService = getDataService()
	local data = if dataService ~= nil then dataService.Get(player) :: Types.ProfileData? else nil
	if data == nil then
		return payload
	end

	payload.equippedId = data.pets.equippedId
	payload.upgradeLevel = PetPerks.ClampLevel(data.pets.upgradeLevel)
	-- Shift-pay upgrade economy (so PetUI can show the next cost + affordability).
	payload.shiftPay = data.shiftPay or 0
	local costs = GameConstants.PET_UPGRADE_PAY_COSTS :: { number }
	payload.nextPayCost = costs[payload.upgradeLevel + 1] -- nil at the cap

	-- Roster order (RarityTable.CRYPTLINGS) keeps the PetUI list deterministic.
	local ownedIds: { string } = {}
	for _, def in RarityTable.CRYPTLINGS :: { any } do
		if (data.collection[def.id] or 0) > 0 then
			table.insert(ownedIds, def.id)
		end
	end
	payload.ownedIds = ownedIds
	payload.perk = currentPerk(player)
	return payload
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- PET_TREATS receipt grant (MonetizationService, inside the receipt lock).
-- Non-yielding. Returns false only when the profile is unavailable; at the cap
-- it returns true and grants nothing extra (see header).
function PetService.GrantUpgrade(player: any): boolean
	local dataService = getDataService()
	if dataService == nil or not dataService.IsLoaded(player) then
		return false
	end
	local updated = dataService.Update(player, function(data: Types.ProfileData)
		data.pets.upgradeLevel =
			math.min(PetPerks.ClampLevel(data.pets.upgradeLevel) + 1, GameConstants.PET_UPGRADE_MAX_LEVEL)
	end) == true
	if not updated then
		return false
	end
	applyPerks(player) -- the equipped perk just got stronger
	return true
end

-- Shift-pay pet upgrade (the primary, non-Robux path): spend the escalating
-- PET_UPGRADE_PAY_COSTS[level + 1] from profile.shiftPay to buy the next level.
-- The 249 R$ PET_TREATS dev product remains the Robux alternative.
export type UpgradeResult = { ok: boolean, err: string?, newLevel: number?, cost: number? }

function PetService.UpgradeWithPay(player: any): UpgradeResult
	local dataService = getDataService()
	if dataService == nil or not dataService.IsLoaded(player) then
		return { ok = false, err = "NO_PROFILE" }
	end
	local costs = GameConstants.PET_UPGRADE_PAY_COSTS :: { number }
	local result: UpgradeResult = { ok = false, err = "INTERNAL" }
	dataService.Update(player, function(data: Types.ProfileData)
		local level = PetPerks.ClampLevel(data.pets.upgradeLevel)
		local cost = costs[level + 1]
		if level >= GameConstants.PET_UPGRADE_MAX_LEVEL or type(cost) ~= "number" then
			result = { ok = false, err = "MAX_LEVEL" }
			return
		end
		if (data.shiftPay or 0) < cost then
			result = { ok = false, err = "NOT_ENOUGH_PAY", cost = cost }
			return
		end
		data.shiftPay -= cost
		data.pets.upgradeLevel = level + 1
		result = { ok = true, newLevel = level + 1, cost = cost }
	end)
	if result.ok then
		applyPerks(player) -- the equipped perk just got stronger
	end
	return result
end

-- Mid-session ownership healing (the pet counterpart of ShelfService's
-- reconcileSlots): trading away the last copy of the equipped cryptling must
-- drop the follower + perks NOW, not on the next join. Called by TradeService
-- after each completed trade. Non-yielding; no-op while the pet is still owned
-- or the profile is unavailable.
function PetService.RevalidateEquip(player: any)
	local dataService = getDataService()
	if dataService == nil or not dataService.IsLoaded(player) then
		return
	end
	local data = dataService.Get(player) :: Types.ProfileData?
	if data == nil then
		return
	end
	local equippedId = data.pets.equippedId
	if equippedId == "" or (data.collection[equippedId] or 0) > 0 then
		return
	end
	dataService.Update(player, function(live: Types.ProfileData)
		live.pets.equippedId = ""
	end)
	local state = petStates[player]
	if state ~= nil then
		state.equippedId = ""
		despawnModel(state)
	end
	applyPerks(player)
end

--------------------------------------------------------------------------------
-- Join flow
--------------------------------------------------------------------------------

local function wirePlayer(player: Player)
	if joinWired[player] then
		return
	end
	joinWired[player] = true
	player.CharacterAdded:Connect(function(character: Model)
		local state = petStates[player]
		if state ~= nil then
			despawnModel(state) -- respawn rebuild: fresh snap behind the new spawn
		end
		task.spawn(function()
			-- Fresh humanoid carries no PetHealthApplied attribute: re-apply.
			character:WaitForChild("Humanoid", 10)
			if player.Parent ~= nil and player.Character == character then
				applyPerks(player)
			end
		end)
	end)
end

local function onPlayerJoined(player: Player)
	wirePlayer(player)
	local dataService = getDataService()
	if dataService == nil then
		return
	end
	local deadline = os.clock() + PROFILE_WAIT_TIMEOUT_SECONDS
	while not dataService.IsLoaded(player) do
		if player.Parent == nil or os.clock() >= deadline then
			return
		end
		task.wait(PROFILE_WAIT_POLL_SECONDS)
	end
	if player.Parent == nil then
		return
	end

	local data = dataService.Get(player) :: Types.ProfileData?
	if data == nil then
		return
	end
	local equippedId = data.pets.equippedId
	-- Stale equip (traded the last copy away between sessions): silently clear.
	if equippedId ~= "" and (data.collection[equippedId] or 0) <= 0 then
		dataService.Update(player, function(live: Types.ProfileData)
			live.pets.equippedId = ""
		end)
		equippedId = ""
	end
	getState(player).equippedId = equippedId
	applyPerks(player)
end

--------------------------------------------------------------------------------
-- Loader lifecycle
--------------------------------------------------------------------------------

function PetService:Init()
	-- No yields (loader contract). Remotes already exist (init.server runs
	-- Remotes.InitServer() first).
	local okEquip, errEquip = pcall(function()
		Remotes.GetFunction("Pet.Equip").OnServerInvoke = function(player: Player, cryptlingId: any)
			return onEquip(player, cryptlingId)
		end
	end)
	if not okEquip then
		warn(`[PetService] Pet.Equip bind failed: {errEquip}`)
	end

	local okState, errState = pcall(function()
		Remotes.GetFunction("Pet.GetState").OnServerInvoke = function(player: Player)
			return onGetState(player)
		end
	end)
	if not okState then
		warn(`[PetService] Pet.GetState bind failed: {errState}`)
	end

	local okPay, errPay = pcall(function()
		Remotes.GetFunction("Pet.UpgradeWithPay").OnServerInvoke = function(player: Player)
			return PetService.UpgradeWithPay(player)
		end
	end)
	if not okPay then
		warn(`[PetService] Pet.UpgradeWithPay bind failed: {errPay}`)
	end

	Players.PlayerAdded:Connect(function(player: Player)
		task.spawn(onPlayerJoined, player)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		local state = petStates[player]
		if state ~= nil then
			despawnModel(state)
		end
		petStates[player] = nil
		joinWired[player] = nil
	end)
end

function PetService:Start()
	-- Players who joined before this service loaded (loader races PlayerAdded).
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerJoined, player)
	end

	RunService.Heartbeat:Connect(function(dt: number)
		for player, state in petStates do
			updatePet(player, state, dt)
		end
	end)
end

return PetService
