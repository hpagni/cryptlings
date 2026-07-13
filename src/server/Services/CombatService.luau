--!strict
-- CRYPTLINGS: NIGHT SHIFT — CombatService (playtest "fight for the box").
-- Server side of the Combat.Attack remote: a player may attack another ONLY
-- while a shift is Active, both are participants, and the TARGET is carrying
-- at least one COMBAT_RARE_CASE_TIER case (§user playtest spec: you fight FOR
-- a rare box, never to grief an empty-handed runner).
--
-- Weapons are limited-use paid consumables (profile.consumables charges):
--   gunShots       Zap blaster    — 30 studs, 40 dmg (cartoony toy laser)
--   swordSwings    Factory blade  — 9 studs, 25 dmg
--   paintballShots Paintball popper — 30 studs, 15 dmg (cheap starter ranged)
--   (none)         bare-hand shove — 9 studs, 10 dmg, always available
-- The best usable weapon for the distance is auto-picked; one charge is
-- consumed per attack THAT LANDS (validation failures never burn charges).
--
-- Damage floors at 1 HP and downs instead of killing: reaching the floor calls
-- ShiftService.DownPlayer(target), whose bleedout path already scatters the
-- carried cases (CaseService.ScatterCarried) — the loot fight resolves there.
--
-- Optional siblings consumed via pcall (degrade gracefully when absent):
--   ShiftService.GetState/IsParticipant/IsDowned/DownPlayer
--   CaseService.GetCarried(player) -> { { uid, tier } }
--   PlayerDataService.Get/Update/IsLoaded · AnalyticsService.Track

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConstants = require(Shared:WaitForChild("Config"):WaitForChild("GameConstants"))
local Remotes = require(Shared:WaitForChild("Net"):WaitForChild("Remotes"))
local Types = require(Shared:WaitForChild("Types"))

--------------------------------------------------------------------------------
-- Weapon table (ordered best-first; charges = nil means always available)
--------------------------------------------------------------------------------

type Weapon = {
	name: string,
	chargeKind: string?, -- profile.consumables key; nil = bare hands
	damage: number,
	rangeStuds: number,
}

local WEAPONS: { Weapon } = {
	{
		name = "gun",
		chargeKind = "gunShots",
		damage = GameConstants.COMBAT_GUN_DAMAGE,
		rangeStuds = GameConstants.COMBAT_GUN_RANGE_STUDS,
	},
	{
		name = "sword",
		chargeKind = "swordSwings",
		damage = GameConstants.COMBAT_SWORD_DAMAGE,
		rangeStuds = GameConstants.COMBAT_MELEE_RANGE_STUDS,
	},
	{
		name = "paintball",
		chargeKind = "paintballShots",
		damage = GameConstants.COMBAT_PAINTBALL_DAMAGE,
		rangeStuds = GameConstants.COMBAT_GUN_RANGE_STUDS,
	},
	-- Free floor pickups (cartoon tier): better than bare hands, strictly
	-- below every paid weapon.
	{
		name = "nunchucks",
		chargeKind = "nunchuckSwings",
		damage = GameConstants.COMBAT_NUNCHUCK_DAMAGE,
		rangeStuds = GameConstants.COMBAT_MELEE_RANGE_STUDS,
	},
	{
		name = "boxingGloves",
		chargeKind = "boxingGloveSwings",
		damage = GameConstants.COMBAT_BOXING_DAMAGE,
		rangeStuds = GameConstants.COMBAT_MELEE_RANGE_STUDS,
	},
	{
		name = "shove",
		chargeKind = nil,
		damage = GameConstants.COMBAT_SHOVE_DAMAGE,
		rangeStuds = GameConstants.COMBAT_MELEE_RANGE_STUDS,
	},
}

local CombatService = {}

local lastAttackAt: { [Player]: number } = {}

--------------------------------------------------------------------------------
-- Lazy sibling resolution (house pattern)
--------------------------------------------------------------------------------

local siblingCache: { [string]: any } = {}

local function getSibling(name: string): any
	local cached = siblingCache[name]
	if cached ~= nil then
		return if cached == false then nil else cached
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

--------------------------------------------------------------------------------
-- Validation helpers
--------------------------------------------------------------------------------

local function getRoot(player: Player): BasePart?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return if root ~= nil and root:IsA("BasePart") then root else nil
end

local function isDowned(shift: any, player: Player): boolean
	if shift ~= nil and type(shift.IsDowned) == "function" then
		local ok, downed = pcall(shift.IsDowned, player)
		return ok and downed == true
	end
	return false
end

-- The fight gate: the target must carry at least one rare case.
local function carriesRareCase(target: Player): boolean
	local caseService = getSibling("CaseService")
	if caseService == nil or type(caseService.GetCarried) ~= "function" then
		return false
	end
	local ok, carried = pcall(caseService.GetCarried, target)
	if not ok or type(carried) ~= "table" then
		return false
	end
	for _, stub in carried do
		if type(stub) == "table" and stub.tier >= GameConstants.COMBAT_RARE_CASE_TIER then
			return true
		end
	end
	return false
end

-- Best usable weapon for this attacker at this distance. Bare-hand shove has
-- no charges; paid weapons need charges in profile.consumables.
local function pickWeapon(attacker: Player, distance: number): Weapon?
	local dataService = getSibling("PlayerDataService")
	local data: Types.ProfileData? = nil
	if dataService ~= nil and type(dataService.Get) == "function" and dataService.IsLoaded(attacker) then
		data = dataService.Get(attacker)
	end
	for _, weapon in WEAPONS do
		if distance <= weapon.rangeStuds then
			if weapon.chargeKind == nil then
				return weapon
			end
			local owned = if data ~= nil then (data.consumables :: any)[weapon.chargeKind] else nil
			if type(owned) == "number" and owned > 0 then
				return weapon
			end
		end
	end
	return nil
end

--------------------------------------------------------------------------------
-- Held-weapon visual: the best charged weapon renders welded to the player's
-- right hand so pickups/purchases are visible on the character. Refreshed on
-- spawn, pickup, and every charge spend.
--------------------------------------------------------------------------------

local heldVisuals: { [Player]: Model } = {}
local heldKinds: { [Player]: string } = {} -- change detection: rebuild only when the best weapon changes

-- First charged weapon in WEAPONS order (= highest damage); nil if bare-handed.
local function bestOwnedWeapon(player: Player): Weapon?
	local dataService = getSibling("PlayerDataService")
	if dataService == nil or type(dataService.Get) ~= "function" or not dataService.IsLoaded(player) then
		return nil
	end
	local data = dataService.Get(player)
	if data == nil then
		return nil
	end
	for _, weapon in WEAPONS do
		if weapon.chargeKind ~= nil then
			local owned = (data.consumables :: any)[weapon.chargeKind]
			if type(owned) == "number" and owned > 0 then
				return weapon
			end
		end
	end
	return nil
end

local function visualPart(parent: Instance, size: Vector3, color: Color3, neon: boolean?): Part
	local part = Instance.new("Part")
	part.Anchored = false
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.Massless = true
	part.Size = size
	part.Color = color
	part.Material = if neon then Enum.Material.Neon else Enum.Material.SmoothPlastic
	part.Parent = parent
	return part
end

local function weldToHand(hand: BasePart, part: BasePart, offset: CFrame)
	part.CFrame = hand.CFrame * offset
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = hand
	weld.Part1 = part
	weld.Parent = part
end

function CombatService.RefreshHeldWeapon(player: Player)
	local weapon = bestOwnedWeapon(player)
	local character = player.Character

	-- Unchanged and still attached to the live character: nothing to do.
	local current = heldVisuals[player]
	if current ~= nil and current.Parent == character and weapon ~= nil and heldKinds[player] == weapon.name then
		return
	end

	if current ~= nil then
		heldVisuals[player] = nil
		current:Destroy()
	end
	heldKinds[player] = if weapon ~= nil then weapon.name else nil :: any

	if weapon == nil or character == nil then
		return
	end
	local hand = character:FindFirstChild("RightHand") or character:FindFirstChild("Right Arm")
	if hand == nil or not hand:IsA("BasePart") then
		return
	end

	local model = Instance.new("Model")
	model.Name = "HeldWeapon"

	if weapon.name == "gun" then
		local body = visualPart(model, Vector3.new(0.45, 0.6, 1.5), Color3.fromRGB(70, 200, 235))
		weldToHand(hand, body, CFrame.new(0, -0.4, -0.5))
		local tip = visualPart(model, Vector3.new(0.3, 0.3, 0.3), Color3.fromRGB(160, 255, 250), true)
		tip.Shape = Enum.PartType.Ball
		weldToHand(hand, tip, CFrame.new(0, -0.4, -1.35))
	elseif weapon.name == "sword" then
		local blade = visualPart(model, Vector3.new(0.18, 0.45, 2.4), Color3.fromRGB(200, 205, 215))
		weldToHand(hand, blade, CFrame.new(0, -0.4, -1.3))
		local guard = visualPart(model, Vector3.new(0.7, 0.5, 0.2), Color3.fromRGB(60, 60, 66))
		weldToHand(hand, guard, CFrame.new(0, -0.4, -0.2))
	elseif weapon.name == "paintball" then
		local body = visualPart(model, Vector3.new(0.5, 0.5, 1.2), Color3.fromRGB(95, 200, 100))
		weldToHand(hand, body, CFrame.new(0, -0.4, -0.45))
		local hopper = visualPart(model, Vector3.new(0.45, 0.45, 0.45), Color3.fromRGB(60, 140, 70))
		hopper.Shape = Enum.PartType.Ball
		weldToHand(hand, hopper, CFrame.new(0, 0, -0.6))
	elseif weapon.name == "nunchucks" then
		local stickA = visualPart(model, Vector3.new(1.5, 0.35, 0.35), Color3.fromRGB(120, 90, 60))
		stickA.Shape = Enum.PartType.Cylinder
		weldToHand(hand, stickA, CFrame.new(0, -0.5, 0) * CFrame.Angles(0, 0, math.rad(90)))
		local stickB = visualPart(model, Vector3.new(1.5, 0.35, 0.35), Color3.fromRGB(120, 90, 60))
		stickB.Shape = Enum.PartType.Cylinder
		weldToHand(hand, stickB, CFrame.new(0.35, -1.2, -0.4) * CFrame.Angles(0, 0, math.rad(60)))
		local link = visualPart(model, Vector3.new(0.5, 0.12, 0.12), Color3.fromRGB(235, 190, 52), true)
		weldToHand(hand, link, CFrame.new(0.18, -1.2, -0.2))
	else -- boxingGloves
		local glove = visualPart(model, Vector3.new(1.1, 1.1, 1.1), Color3.fromRGB(220, 60, 60))
		glove.Shape = Enum.PartType.Ball
		weldToHand(hand, glove, CFrame.new(0, -0.35, 0))
	end

	model.Parent = character
	heldVisuals[player] = model
end

--------------------------------------------------------------------------------
-- Combat.Attack
--------------------------------------------------------------------------------

-- Spends one charge of `weapon` (no-op success for bare hands). Returns
-- remaining charges (nil for bare hands) or false on failure.
local function consumeCharge(attacker: Player, weapon: Weapon): (boolean, number?)
	if weapon.chargeKind == nil then
		return true, nil
	end
	local dataService = getSibling("PlayerDataService")
	if dataService == nil or not dataService.IsLoaded(attacker) then
		return false, nil
	end
	local consumed = false
	local charges: number? = nil
	local updated = dataService.Update(attacker, function(data: Types.ProfileData)
		local bag = data.consumables :: any
		local owned = bag[weapon.chargeKind :: string]
		if type(owned) == "number" and owned > 0 then
			bag[weapon.chargeKind :: string] = owned - 1
			charges = owned - 1
			consumed = true
		end
	end)
	if updated ~= true or not consumed then
		return false, nil
	end
	CombatService.RefreshHeldWeapon(attacker) -- charge change may demote the held weapon
	return true, charges
end

-- targetUserId 0: swing at the DEFECT. No rare-case gate (it has no loot) —
-- a landed hit costs a charge, knocks the monster back, and staggers it for a
-- few seconds (DefectService.ApplyStagger) so a cornered runner can escape.
local function onAttackDefect(attacker: Player): { [string]: any }
	local attackerRoot = getRoot(attacker)
	if attackerRoot == nil then
		return { ok = false, err = "NO_CHARACTER" }
	end

	-- Nearest tagged Defect to the attacker: with concurrent shift floors
	-- (R2 Change 6) a global first-match can resolve another floor's monster
	-- 2000+ studs away; the 2000-stud slot pitch makes nearest-match exact.
	local defectRoot: BasePart? = nil
	local bestDistance = math.huge
	for _, tagged in CollectionService:GetTagged("Defect") do
		if tagged:IsA("Model") and tagged.PrimaryPart ~= nil then
			local candidate = (tagged.PrimaryPart.Position - attackerRoot.Position).Magnitude
			if candidate < bestDistance then
				bestDistance = candidate
				defectRoot = tagged.PrimaryPart
			end
		end
	end
	if defectRoot == nil then
		return { ok = false, err = "NO_TARGET" }
	end

	local offset = defectRoot.Position - attackerRoot.Position
	local distance = Vector3.new(offset.X, 0, offset.Z).Magnitude -- planar: its root rides high
	local weapon = pickWeapon(attacker, distance)
	if weapon == nil then
		return { ok = false, err = "OUT_OF_RANGE" }
	end

	local spent, charges = consumeCharge(attacker, weapon)
	if not spent then
		return { ok = false, err = "NO_CHARGES" }
	end
	lastAttackAt[attacker] = os.clock()

	local flat = Vector3.new(offset.X, 0, offset.Z)
	if flat.Magnitude > 0.05 then
		defectRoot.AssemblyLinearVelocity = flat.Unit * GameConstants.COMBAT_KNOCKBACK_SPEED * 0.6
	end
	local defectService = getSibling("DefectService")
	if defectService ~= nil and type(defectService.ApplyStagger) == "function" then
		pcall(defectService.ApplyStagger, 2.5)
	end

	track(attacker, "combat_attack", { weapon = weapon.name, target = "defect" })
	return { ok = true, weapon = weapon.name, stagger = true, charges = charges }
end

local function onAttack(attacker: Player, targetUserId: any): { [string]: any }
	if type(targetUserId) ~= "number" then
		return { ok = false, err = "BAD_ARG" }
	end

	local now = os.clock()
	local lastSwing = lastAttackAt[attacker]
	if lastSwing ~= nil and now - lastSwing < GameConstants.COMBAT_COOLDOWN_SECONDS then
		return { ok = false, err = "COOLDOWN" }
	end

	local shift = getSibling("ShiftService")
	if shift == nil or type(shift.GetState) ~= "function" then
		return { ok = false, err = "NO_SHIFT" }
	end
	local stateOk, state = pcall(shift.GetState)
	if not stateOk or state ~= "Active" then
		return { ok = false, err = "NOT_ACTIVE" }
	end
	if isDowned(shift, attacker) then
		return { ok = false, err = "DOWNED" }
	end

	if targetUserId == 0 then
		return onAttackDefect(attacker)
	end

	local target = Players:GetPlayerByUserId(targetUserId)
	if target == nil or target == attacker then
		return { ok = false, err = "NO_TARGET" }
	end

	if type(shift.IsParticipant) == "function" then
		local aOk, aIn = pcall(shift.IsParticipant, attacker)
		local tOk, tIn = pcall(shift.IsParticipant, target)
		if not aOk or aIn ~= true or not tOk or tIn ~= true then
			return { ok = false, err = "NOT_PARTICIPANT" }
		end
	end
	if isDowned(shift, target) then
		return { ok = false, err = "DOWNED" }
	end
	if not carriesRareCase(target) then
		return { ok = false, err = "NO_RARE_CASE" } -- fights are FOR a rare box only
	end

	local attackerRoot = getRoot(attacker)
	local targetRoot = getRoot(target)
	if attackerRoot == nil or targetRoot == nil then
		return { ok = false, err = "NO_CHARACTER" }
	end
	local distance = (targetRoot.Position - attackerRoot.Position).Magnitude
	local weapon = pickWeapon(attacker, distance)
	if weapon == nil then
		return { ok = false, err = "OUT_OF_RANGE" }
	end

	-- Resolve the target humanoid BEFORE consuming a charge: a dead or missing
	-- humanoid must never burn a charge, and damaging a corpse would otherwise
	-- "floor" it back up to 1 HP (resurrecting it) below.
	local humanoid = target.Character and target.Character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil or humanoid.Health <= 0 then
		return { ok = false, err = "NO_CHARACTER" }
	end

	-- Consume the charge first, atomically; a failed consume aborts the hit.
	local spent, charges = consumeCharge(attacker, weapon)
	if not spent then
		return { ok = false, err = "NO_CHARGES" }
	end

	lastAttackAt[attacker] = now

	-- Damage floors at 1 HP: reaching the floor downs the target instead of
	-- killing them (DownPlayer scatters their carried cases — the prize).
	-- Equipped-pet PVP perk ("PetPvpStrength"): scales the attacker's outgoing
	-- damage by 1 + strength (a brawler pet hits harder in the fight-for-the-box).
	local pvp = tonumber(attacker:GetAttribute("PetPvpStrength")) or 0
	local dealt = weapon.damage * (1 + math.max(pvp, 0))
	local downed = false
	local newHealth = humanoid.Health - dealt
	if newHealth <= 1 then
		humanoid.Health = 1
		downed = true
	else
		humanoid.Health = newHealth
	end

	-- Knockback away from the attacker (flat, slight pop upward).
	local away = targetRoot.Position - attackerRoot.Position
	local flat = Vector3.new(away.X, 0, away.Z)
	if flat.Magnitude > 0.05 then
		targetRoot.AssemblyLinearVelocity = flat.Unit * GameConstants.COMBAT_KNOCKBACK_SPEED
			+ Vector3.new(0, GameConstants.COMBAT_KNOCKBACK_SPEED * 0.3, 0)
	end

	if downed and type(shift.DownPlayer) == "function" then
		local ok, err = pcall(shift.DownPlayer, target)
		if not ok then
			warn(`[CombatService] DownPlayer failed: {err}`)
		end
	end

	track(attacker, "combat_attack", { weapon = weapon.name, downed = downed })
	return { ok = true, weapon = weapon.name, downed = downed, charges = charges }
end

--------------------------------------------------------------------------------
-- Floor weapon pickups (cartoon tier): ShiftService calls SpawnFloorWeapons
-- alongside CaseService.SpawnForShift. Pickups parent under the floor model so
-- floor teardown removes any unclaimed ones.
--------------------------------------------------------------------------------

type FloorWeapon = {
	chargeKind: string,
	display: string,
	charges: number,
}

local FLOOR_WEAPONS: { FloorWeapon } = {
	{
		chargeKind = "boxingGloveSwings",
		display = "Boxing Gloves",
		charges = GameConstants.FLOOR_WEAPON_BOXING_CHARGES,
	},
	{
		chargeKind = "nunchuckSwings",
		display = "Nunchucks",
		charges = GameConstants.FLOOR_WEAPON_NUNCHUCK_CHARGES,
	},
}

local function pickupPart(parent: Instance, size: Vector3, cframe: CFrame, color: Color3): Part
	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = false
	part.Size = size
	part.CFrame = cframe
	part.Color = color
	part.Material = Enum.Material.SmoothPlastic
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

local function spawnPickup(parent: Instance, kind: FloorWeapon, position: Vector3, yaw: number)
	local model = Instance.new("Model")
	model.Name = `FloorWeapon_{kind.chargeKind}`

	local base = CFrame.new(position) * CFrame.Angles(0, yaw, 0)
	local stand =
		pickupPart(model, Vector3.new(2.6, 0.4, 2.6), base * CFrame.new(0, 0.2, 0), Color3.fromRGB(60, 62, 70))
	stand.CanCollide = true

	if kind.chargeKind == "boxingGloveSwings" then
		local left =
			pickupPart(model, Vector3.new(1.2, 1.2, 1.2), base * CFrame.new(-0.7, 1.1, 0), Color3.fromRGB(220, 60, 60))
		left.Shape = Enum.PartType.Ball
		local right =
			pickupPart(model, Vector3.new(1.2, 1.2, 1.2), base * CFrame.new(0.7, 1.1, 0), Color3.fromRGB(220, 60, 60))
		right.Shape = Enum.PartType.Ball
	else
		local stickA = pickupPart(
			model,
			Vector3.new(1.6, 0.4, 0.4),
			base * CFrame.new(-0.7, 1.1, 0) * CFrame.Angles(0, 0, math.rad(60)),
			Color3.fromRGB(120, 90, 60)
		)
		stickA.Shape = Enum.PartType.Cylinder
		local stickB = pickupPart(
			model,
			Vector3.new(1.6, 0.4, 0.4),
			base * CFrame.new(0.7, 1.1, 0) * CFrame.Angles(0, 0, math.rad(-60)),
			Color3.fromRGB(120, 90, 60)
		)
		stickB.Shape = Enum.PartType.Cylinder
		local link =
			pickupPart(model, Vector3.new(0.9, 0.15, 0.15), base * CFrame.new(0, 1.45, 0), Color3.fromRGB(235, 190, 52))
		link.Material = Enum.Material.Neon
	end

	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Take"
	prompt.ObjectText = `{kind.display} ({kind.charges} swings)`
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 10
	prompt.RequiresLineOfSight = false
	prompt.Parent = stand

	local taken = false
	prompt.Triggered:Connect(function(player: Player)
		if taken then
			return
		end
		local dataService = getSibling("PlayerDataService")
		if dataService == nil or not dataService.IsLoaded(player) then
			return
		end
		taken = true
		local updated = dataService.Update(player, function(data: Types.ProfileData)
			local bag = data.consumables :: any
			local owned = bag[kind.chargeKind]
			bag[kind.chargeKind] = (if type(owned) == "number" then owned else 0) + kind.charges
		end)
		if updated == true then
			track(player, "floor_weapon_pickup", { kind = kind.chargeKind })
			model:Destroy()
			CombatService.RefreshHeldWeapon(player) -- show it in hand right away
		else
			taken = false -- write failed: leave the pickup for a retry
		end
	end)

	model.Parent = parent
end

-- Scatters FLOOR_WEAPON_SPAWNS pickups near random PatrolNodes of this floor
-- (deterministic from the shift rng, like cases and decorations).
function CombatService.SpawnFloorWeapons(floorRoot: Instance, rng: Random)
	local spots: { Vector3 } = {}
	for _, tagged in CollectionService:GetTagged("PatrolNode") do
		if tagged:IsA("BasePart") and tagged:IsDescendantOf(floorRoot) then
			table.insert(spots, tagged.Position)
		end
	end
	if #spots == 0 then
		return
	end
	for _ = 1, GameConstants.FLOOR_WEAPON_SPAWNS do
		local kind = FLOOR_WEAPONS[rng:NextInteger(1, #FLOOR_WEAPONS)]
		local spot = spots[rng:NextInteger(1, #spots)]
		local position = Vector3.new(
			spot.X + rng:NextNumber(-6, 6),
			spot.Y - 2, -- PatrolNodes float 2 studs up; pickups sit on the ground
			spot.Z + rng:NextNumber(-6, 6)
		)
		spawnPickup(floorRoot, kind, position, rng:NextNumber(0, math.pi * 2))
	end
end

--------------------------------------------------------------------------------
-- Loader lifecycle
--------------------------------------------------------------------------------

function CombatService:Init()
	local ok, err = pcall(function()
		Remotes.GetFunction("Combat.Attack").OnServerInvoke = onAttack
	end)
	if not ok then
		warn(`[CombatService] remote bind failed: {err}`)
	end

	Players.PlayerRemoving:Connect(function(player)
		lastAttackAt[player] = nil
		heldVisuals[player] = nil -- model dies with the character
		heldKinds[player] = nil
	end)

	-- Held-weapon visual follows the character across spawns (and shows up as
	-- soon as the profile loads with charges already owned).
	local function hookPlayer(player: Player)
		player.CharacterAdded:Connect(function()
			task.delay(1, CombatService.RefreshHeldWeapon, player)
		end)
		if player.Character ~= nil then
			task.delay(1, CombatService.RefreshHeldWeapon, player)
		end
	end
	Players.PlayerAdded:Connect(hookPlayer)
	for _, player in Players:GetPlayers() do
		hookPlayer(player)
	end

	-- Shop purchases grant charges without a pickup/spend event, so a slow
	-- poll keeps the held visual honest (change-detected: no-op when the
	-- best weapon hasn't changed).
	task.spawn(function()
		while true do
			for _, player in Players:GetPlayers() do
				CombatService.RefreshHeldWeapon(player)
			end
			task.wait(4)
		end
	end)
end

return CombatService
