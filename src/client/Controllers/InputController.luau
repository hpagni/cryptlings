--!strict
-- CRYPTLINGS: NIGHT SHIFT — InputController (Stage 1, module mobile-run-ui).
-- One-thumb mobile controls per SOP §3.2 with full PC parity:
--   * Movement: default Roblox dynamic thumbstick (left thumb).
--   * Right-side ContextActionService touch buttons (>= 44px, §G mobile gates):
--       SPRINT  — toggle; sets WalkSpeed to SPRINT_SPEED client-side (server
--                 validates <= cap), carry slowdown CARRY_SPEED_MULT_PER_CASE^n.
--       GRAB/DROP — contextual: nearest tagged case <= GRAB_RANGE_STUDS ->
--                 RequestPickupCase, else own carried stack -> RequestDropCase.
--       REVIVE  — contextual: nearest downed teammate <= REVIVE_RANGE_STUDS,
--                 hold REVIVE_HOLD_SECONDS with progress ring ->
--                 RequestReviveTeammate.
--   * Keyboard parity: LeftShift = sprint, E = grab/drop, F = revive (hold).
-- Fires FunnelClient "client_spawn_ready" once controls are bound (server
-- counts CoreLoop funnel step 1 on it).
--
-- Case discovery convention (CaseService owns the world side): every grabbable
-- case Model carries CollectionService tag "Case" + string attribute "caseUid".
-- Cases parented under a character (i.e. being carried) are not grab targets,
-- EXCEPT when that holder is downed — §1.2's "carry out a downed friend's
-- boxes" steal, which the server validates in CaseService.onRequestPickup.

local CollectionService = game:GetService("CollectionService")
local ContextActionService = game:GetService("ContextActionService")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConstants = require(Shared:WaitForChild("Config"):WaitForChild("GameConstants"))
local Remotes = require(Shared:WaitForChild("Net"):WaitForChild("Remotes"))

local LocalPlayer = Players.LocalPlayer

--------------------------------------------------------------------------------
-- UI-local tuning (interaction ranges are this module's spec, not §G constants)
--------------------------------------------------------------------------------

-- Interaction ranges come from GameConstants so the server (CaseService /
-- ShiftService) validates with EXACTLY the numbers the client targets with.
local GRAB_RANGE_STUDS = GameConstants.PICKUP_RANGE_STUDS
local REVIVE_RANGE_STUDS = GameConstants.REVIVE_RANGE_STUDS
local CONTEXT_POLL_SECONDS = 0.15 -- contextual button refresh cadence
local CASE_TAG = "Case"
local CASE_UID_ATTRIBUTE = "caseUid"
local DEFECT_TAG = "Defect"

local ACTION_SPRINT = "NS_Sprint"
local ACTION_GRAB_DROP = "NS_GrabDrop"
local ACTION_REVIVE = "NS_Revive"
local ACTION_ATTACK = "NS_Attack"
local ACTION_EXIT_WARP = "NS_ExitWarp"

-- Widest weapon range; per-weapon ranges are validated server-side.
local ATTACK_RANGE_STUDS = GameConstants.COMBAT_GUN_RANGE_STUDS

-- Touch button sizing/placement — all on the RIGHT side for one-thumb play
-- (left thumb owns the dynamic thumbstick). Sizes comfortably exceed the
-- 44px MOBILE_MIN_TOUCH_TARGET_PX gate.
local GRAB_BUTTON_PX = 78
local SPRINT_BUTTON_PX = 64
local REVIVE_BUTTON_PX = 64
local ATTACK_BUTTON_PX = 64

local COLOR_ENABLED = Color3.fromRGB(255, 255, 255)
local COLOR_DISABLED = Color3.fromRGB(120, 120, 120)
local COLOR_SPRINT_ON = Color3.fromRGB(120, 230, 130)
local COLOR_REVIVE_RING = Color3.fromRGB(110, 220, 120)

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local InputController = {}

local registryRef: any = nil
local carryController: any = nil -- CarryController public table (via registry)

local sprinting = false
local localDowned = false
local maxCarry = GameConstants.BASE_CARRY_SLOTS

-- Downed teammates: userId -> last broadcast position (Vector3?), kept fresh by
-- live character positions when available.
local downedTeammates: { [number]: Vector3? } = {}

-- Revive hold state.
local reviveTargetUserId: number? = nil
local reviveHoldStart: number? = nil
local reviveProgress = 0
local reviveBusy = false -- a RequestReviveTeammate invoke is in flight

local grabBusy = false -- a pickup/drop invoke is in flight
local attackBusy = false -- a Combat.Attack invoke is in flight
local warpBusy = false -- a Consumable.Use("exitWarp") invoke is in flight

local sprintChanged = Instance.new("BindableEvent")

-- Remotes (resolved in Start; Remotes.Get yields on the client).
local requestPickupCase: RemoteFunction? = nil
local requestDropCase: RemoteFunction? = nil
local requestReviveTeammate: RemoteFunction? = nil
local requestAttack: RemoteFunction? = nil
local consumableUse: RemoteFunction? = nil
local shopGetCatalog: RemoteFunction? = nil

-- Hold-ring gui pieces (built in Start).
local holdGuiFrame: Frame? = nil
local holdGuiFill: Frame? = nil
local touchRingFill: Frame? = nil

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function getLocalRootPart(): BasePart?
	local character = LocalPlayer.Character
	if character == nil then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if root ~= nil and root:IsA("BasePart") then
		return root
	end
	return nil
end

local function getLocalHumanoid(): Humanoid?
	local character = LocalPlayer.Character
	if character == nil then
		return nil
	end
	return character:FindFirstChildOfClass("Humanoid")
end

local function getCarriedCount(): number
	if carryController ~= nil and type(carryController.GetLocalCount) == "function" then
		return carryController.GetLocalCount()
	end
	return 0
end

local function getCarriedUids(): { string }
	if carryController ~= nil and type(carryController.GetLocalCarriedUids) == "function" then
		return carryController.GetLocalCarriedUids()
	end
	return {}
end

-- Client-side walk speed: SPRINT_SPEED when sprint toggled (server validates
-- <= cap), WALKSPEED_BASE otherwise, both slowed per carried case (§G).
-- R3-5 (Addendum 2; R3 plan decision §6): the lobby bicycle folds in here as
--   effectiveBase = max(sprintOrWalkBase + petSpeed,
--                       (WALKSPEED_BASE + petSpeed) * bikeMult)
-- read off the server-set "BikeActive" attribute (BikeService's mirror).
-- Precedence is max(bike path, sprint path) — bike NEVER stacks with sprint.
-- This function and server CaseService.ApplyCarrySpeed are the ONLY two
-- WalkSpeed owners (PetPerks line 8: never a third writer); both multiply the
-- same carry penalty last, so the owners always agree (carry only happens on
-- floors where the bike is always cleared — theoretical, but unified).
local function applyWalkSpeed()
	if localDowned then
		return -- the server owns movement while downed
	end
	local humanoid = getLocalHumanoid()
	if humanoid == nil or humanoid.Health <= 0 then
		return
	end
	local base = if sprinting then GameConstants.SPRINT_SPEED else GameConstants.WALKSPEED_BASE
	-- Equipped-pet speed perk ("PetSpeedBonus", server-published): additive to
	-- base before the carry penalty — mirrors CaseService.ApplyCarrySpeed so the
	-- two WalkSpeed owners never disagree.
	local pet = tonumber(LocalPlayer:GetAttribute("PetSpeedBonus")) or 0
	-- Lobby bicycle factor (R3-5): server-set attribute, no stacking (max()).
	local bikeMult = if LocalPlayer:GetAttribute("BikeActive") == true then GameConstants.BIKE_SPEED_MULT else 1
	base = math.max(base + pet, (GameConstants.WALKSPEED_BASE + pet) * bikeMult)
	-- Steady Grips (run-scoped server attribute): no carry slowdown at all.
	local mult = if LocalPlayer:GetAttribute("CarrySpeedExempt") == true
		then 1
		else GameConstants.CARRY_SPEED_MULT_PER_CASE ^ getCarriedCount()
	humanoid.WalkSpeed = base * mult
end

local function instancePosition(instance: Instance): Vector3?
	if instance:IsA("BasePart") then
		return instance.Position
	elseif instance:IsA("Model") then
		return instance:GetPivot().Position
	end
	return nil
end

-- True when this tagged case is grab-blocked because it is being carried.
-- §1.2 steal-from-downed exception: a case on a DOWNED teammate's body IS a
-- valid grab target ("carry out a downed friend's boxes") — the server
-- validates the same rule in CaseService.onRequestPickup.
local function isBlockedCarriedCase(instance: Instance): boolean
	for _, player in Players:GetPlayers() do
		local character = player.Character
		if character ~= nil and instance:IsDescendantOf(character) then
			if player ~= LocalPlayer and downedTeammates[player.UserId] ~= nil then
				return false -- downed holder: lootable
			end
			return true -- own stack or a living holder: not a grab target
		end
	end
	return false
end

-- Nearest grabbable floor case within GRAB_RANGE_STUDS, or nil.
local function findNearestCase(): (string?, number)
	local root = getLocalRootPart()
	if root == nil then
		return nil, math.huge
	end
	local origin = root.Position
	local bestUid: string? = nil
	local bestDistance = GRAB_RANGE_STUDS
	for _, instance in CollectionService:GetTagged(CASE_TAG) do
		local uid = instance:GetAttribute(CASE_UID_ATTRIBUTE)
		if type(uid) == "string" and not isBlockedCarriedCase(instance) then
			local position = instancePosition(instance)
			if position ~= nil then
				local distance = (position - origin).Magnitude
				if distance <= bestDistance then
					bestDistance = distance
					bestUid = uid
				end
			end
		end
	end
	return bestUid, bestDistance
end

-- Distance to one downed teammate, or math.huge when unknown. Prefers the live
-- character position; falls back to the PlayerDownedState broadcast position.
local function downedTeammateDistance(userId: number): number
	local root = getLocalRootPart()
	if root == nil then
		return math.huge
	end
	local position: Vector3? = downedTeammates[userId]
	local teammate = Players:GetPlayerByUserId(userId)
	if teammate ~= nil and teammate.Character ~= nil then
		local teammateRoot = teammate.Character:FindFirstChild("HumanoidRootPart")
		if teammateRoot ~= nil and teammateRoot:IsA("BasePart") then
			position = teammateRoot.Position
		end
	end
	if position == nil then
		return math.huge
	end
	return (position - root.Position).Magnitude
end

-- Nearest downed teammate within REVIVE_RANGE_STUDS, or nil.
local function findNearestDownedTeammate(): number?
	local bestUserId: number? = nil
	local bestDistance = REVIVE_RANGE_STUDS
	for userId in downedTeammates do
		local distance = downedTeammateDistance(userId)
		if distance <= bestDistance then
			bestDistance = distance
			bestUserId = userId
		end
	end
	return bestUserId
end

--------------------------------------------------------------------------------
-- Touch button styling
--------------------------------------------------------------------------------

local function styleButton(actionName: string, sizePx: number, position: UDim2)
	local button = ContextActionService:GetButton(actionName)
	if button == nil then
		return -- not a touch device
	end
	button.Size = UDim2.fromOffset(sizePx, sizePx)
	ContextActionService:SetPosition(actionName, position)
end

local function setButtonLook(actionName: string, enabled: boolean, color: Color3?)
	local button = ContextActionService:GetButton(actionName)
	if button == nil then
		return
	end
	button.ImageColor3 = if enabled then (color or COLOR_ENABLED) else COLOR_DISABLED
	button.ImageTransparency = if enabled then 0.25 else 0.6
	local title = button:FindFirstChild("ActionTitle")
	if title ~= nil and title:IsA("TextLabel") then
		title.TextTransparency = if enabled then 0 else 0.45
	end
end

-- Progress ring overlaid on the touch revive button (greybox: a circular fill
-- that grows 0 -> 1 behind the icon while the player holds).
local function ensureTouchRing()
	if touchRingFill ~= nil and touchRingFill.Parent ~= nil then
		return
	end
	local button = ContextActionService:GetButton(ACTION_REVIVE)
	if button == nil then
		return
	end
	local ring = Instance.new("Frame")
	ring.Name = "ReviveHoldRing"
	ring.AnchorPoint = Vector2.new(0.5, 0.5)
	ring.Position = UDim2.fromScale(0.5, 0.5)
	ring.Size = UDim2.fromScale(0, 0)
	ring.BackgroundColor3 = COLOR_REVIVE_RING
	ring.BackgroundTransparency = 0.35
	ring.BorderSizePixel = 0
	ring.ZIndex = button.ZIndex + 1
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = ring
	ring.Parent = button
	touchRingFill = ring
end

-- Small center-screen hold indicator so keyboard (F-hold) players see the
-- same REVIVE_HOLD_SECONDS ring (PC parity).
local function buildHoldGui()
	local playerGui = LocalPlayer:WaitForChild("PlayerGui")

	local gui = Instance.new("ScreenGui")
	gui.Name = "ReviveHoldGui"
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = false
	gui.DisplayOrder = 20

	local frame = Instance.new("Frame")
	frame.Name = "Ring"
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromScale(0.5, 0.66)
	frame.Size = UDim2.fromOffset(64, 64)
	frame.BackgroundColor3 = Color3.fromRGB(20, 24, 22)
	frame.BackgroundTransparency = 0.35
	frame.BorderSizePixel = 0
	frame.Visible = false
	frame.Parent = gui

	local frameCorner = Instance.new("UICorner")
	frameCorner.CornerRadius = UDim.new(1, 0)
	frameCorner.Parent = frame

	local stroke = Instance.new("UIStroke")
	stroke.Color = COLOR_REVIVE_RING
	stroke.Thickness = 2
	stroke.Parent = frame

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.AnchorPoint = Vector2.new(0.5, 0.5)
	fill.Position = UDim2.fromScale(0.5, 0.5)
	fill.Size = UDim2.fromScale(0, 0)
	fill.BackgroundColor3 = COLOR_REVIVE_RING
	fill.BackgroundTransparency = 0.25
	fill.BorderSizePixel = 0
	fill.Parent = frame

	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(1, 0)
	fillCorner.Parent = fill

	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.AnchorPoint = Vector2.new(0.5, 0)
	label.Position = UDim2.new(0.5, 0, 1, 4)
	label.Size = UDim2.fromOffset(120, 18)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextSize = 14
	label.TextColor3 = Color3.fromRGB(235, 245, 235)
	label.TextStrokeTransparency = 0.6
	label.Text = "REVIVING..."
	label.Parent = frame

	gui.Parent = playerGui
	holdGuiFrame = frame
	holdGuiFill = fill
end

local function setHoldProgress(progress: number)
	reviveProgress = math.clamp(progress, 0, 1)
	local visible = reviveProgress > 0
	if holdGuiFrame ~= nil then
		holdGuiFrame.Visible = visible
	end
	if holdGuiFill ~= nil then
		holdGuiFill.Size = UDim2.fromScale(reviveProgress, reviveProgress)
	end
	ensureTouchRing()
	if touchRingFill ~= nil then
		touchRingFill.Size = UDim2.fromScale(reviveProgress, reviveProgress)
		touchRingFill.Visible = visible
	end
end

--------------------------------------------------------------------------------
-- Actions
--------------------------------------------------------------------------------

local function setSprinting(on: boolean)
	if sprinting == on then
		return
	end
	sprinting = on
	applyWalkSpeed()
	setButtonLook(ACTION_SPRINT, true, if sprinting then COLOR_SPRINT_ON else COLOR_ENABLED)
	sprintChanged:Fire(sprinting)
end

local function onSprintAction(_actionName: string, inputState: Enum.UserInputState, _input: InputObject)
	if inputState == Enum.UserInputState.Begin and not localDowned then
		setSprinting(not sprinting)
		return Enum.ContextActionResult.Sink
	end
	return Enum.ContextActionResult.Pass
end

local function doGrabOrDrop()
	if grabBusy or localDowned then
		return
	end
	local nearestUid = findNearestCase()
	local carried = getCarriedUids()
	local uidToPickup: string? = nil
	local uidToDrop: string? = nil
	if nearestUid ~= nil and #carried < maxCarry then
		uidToPickup = nearestUid
	elseif #carried > 0 then
		uidToDrop = carried[#carried] -- drop the most recently grabbed case
	else
		return -- nothing in context; button shows disabled
	end

	grabBusy = true
	task.spawn(function()
		local ok, result = pcall(function()
			if uidToPickup ~= nil and requestPickupCase ~= nil then
				return requestPickupCase:InvokeServer(uidToPickup)
			elseif uidToDrop ~= nil and requestDropCase ~= nil then
				return requestDropCase:InvokeServer(uidToDrop)
			end
			return nil
		end)
		if not ok then
			warn(`[InputController] grab/drop invoke failed: {result}`)
		elseif type(result) == "table" and result.ok ~= true and result.err ~= nil then
			-- Server said no (raced another player, too far, etc.) — context
			-- refresh will restyle the button; nothing else to do client-side.
			warn(`[InputController] grab/drop rejected: {result.err}`)
		end
		grabBusy = false
	end)
end

local function onGrabDropAction(_actionName: string, inputState: Enum.UserInputState, _input: InputObject)
	if inputState == Enum.UserInputState.Begin then
		doGrabOrDrop()
		return Enum.ContextActionResult.Sink
	end
	return Enum.ContextActionResult.Pass
end

-- True when this character carries at least one tier>=COMBAT_RARE_CASE_TIER
-- case (carried cases stay tagged+welded under the character, so the client
-- can inspect them the same way isBlockedCarriedCase does). Mirrors the
-- server's CombatService rare-case gate so we never target a swing the server
-- is guaranteed to reject.
local function carriesRareCase(character: Model): boolean
	for _, instance in CollectionService:GetTagged(CASE_TAG) do
		if instance:IsDescendantOf(character) then
			local tier = instance:GetAttribute("CaseTier")
			if type(tier) == "number" and tier >= GameConstants.COMBAT_RARE_CASE_TIER then
				return true
			end
		end
	end
	return false
end

-- Planar distance to the tagged Defect (its root rides high, so the server's
-- onAttackDefect range check is planar too), or math.huge when absent.
local function findDefectDistance(): number
	local myRoot = getLocalRootPart()
	if myRoot == nil then
		return math.huge
	end
	for _, tagged in CollectionService:GetTagged(DEFECT_TAG) do
		if tagged:IsA("Model") and tagged.PrimaryPart ~= nil then
			local offset = tagged.PrimaryPart.Position - myRoot.Position
			return Vector3.new(offset.X, 0, offset.Z).Magnitude
		end
	end
	return math.huge
end

-- Attack targeting: nearest VALID player target within blaster range — skips
-- downed teammates and non-rare-case carriers (the server rejects both, and a
-- doomed player target would shadow the Defect sentinel). Also returns the
-- distance so doAttack can prefer a closer Defect. The server still enforces
-- the real rules (Active shift, rare-case gate, weapon charges, range).
local function findNearestPlayerUserId(): (number?, number)
	local myRoot = getLocalRootPart()
	if myRoot == nil then
		return nil, math.huge
	end
	local best: number? = nil
	local bestDist = ATTACK_RANGE_STUDS + 1
	for _, player in Players:GetPlayers() do
		if player ~= LocalPlayer and downedTeammates[player.UserId] == nil then
			local character = player.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if root ~= nil and root:IsA("BasePart") and carriesRareCase(character :: Model) then
				local dist = (root.Position - myRoot.Position).Magnitude
				if dist < bestDist then
					best = player.UserId
					bestDist = dist
				end
			end
		end
	end
	return best, bestDist
end

local function doAttack()
	if attackBusy or localDowned then
		return
	end
	-- Swing at the DEFECT (targetUserId 0 is the server's "attack the monster"
	-- sentinel: knockback + stagger, no loot) when no valid player target is in
	-- range, or when the Defect is in range AND closer — the monster actually
	-- bearing down on you beats a teammate's box.
	local playerTarget, playerDist = findNearestPlayerUserId()
	local defectDist = findDefectDistance()
	local targetUserId = playerTarget or 0
	if defectDist <= ATTACK_RANGE_STUDS and defectDist < playerDist then
		targetUserId = 0
	end
	attackBusy = true
	task.spawn(function()
		local ok, result = pcall(function()
			if requestAttack ~= nil then
				return requestAttack:InvokeServer(targetUserId)
			end
			return nil
		end)
		if not ok then
			warn(`[InputController] attack invoke failed: {result}`)
		elseif type(result) == "table" and result.ok ~= true and result.err ~= nil then
			-- Server said no (no rare case on the target, cooldown, range...).
			warn(`[InputController] attack rejected: {result.err}`)
		end
		attackBusy = false
	end)
end

local function onAttackAction(_actionName: string, inputState: Enum.UserInputState, _input: InputObject)
	if inputState == Enum.UserInputState.Begin then
		doAttack()
		return Enum.ContextActionResult.Sink
	end
	return Enum.ContextActionResult.Pass
end

-- Exit warp (EXIT_WARP product): use one to teleport to the dock. Owning none
-- raises the purchase prompt right here, mid-run — this SKU is deliberately
-- exempt from the no-mid-run storefront rule (it is a panic button).
local function doExitWarp()
	if warpBusy or localDowned then
		return
	end
	warpBusy = true
	task.spawn(function()
		local ok, result = pcall(function()
			if consumableUse ~= nil then
				return consumableUse:InvokeServer("exitWarp")
			end
			return nil
		end)
		if ok and type(result) == "table" and result.ok ~= true and result.err == "NONE_OWNED" then
			-- Quick-buy: pull the live catalog for the assetId (0 = not wired
			-- yet -> the prompt is skipped, same as ShopUI's polite path).
			local catalogOk, catalog = pcall(function()
				return if shopGetCatalog ~= nil then shopGetCatalog:InvokeServer() else nil
			end)
			if catalogOk and type(catalog) == "table" and type(catalog.items) == "table" then
				for _, entry in catalog.items :: { any } do
					if entry.sku == "EXIT_WARP" then
						local assetId = tonumber(entry.assetId) or 0
						if assetId > 0 then
							pcall(function()
								MarketplaceService:PromptProductPurchase(LocalPlayer, assetId)
							end)
						else
							warn("[InputController] EXIT_WARP not wired in Creator Dashboard yet")
						end
						break
					end
				end
			end
		elseif not ok then
			warn(`[InputController] exit warp invoke failed: {result}`)
		end
		warpBusy = false
	end)
end

local function onExitWarpAction(_actionName: string, inputState: Enum.UserInputState, _input: InputObject)
	if inputState == Enum.UserInputState.Begin then
		doExitWarp()
		return Enum.ContextActionResult.Sink
	end
	return Enum.ContextActionResult.Pass
end

local function cancelReviveHold()
	reviveTargetUserId = nil
	reviveHoldStart = nil
	setHoldProgress(0)
end

local function beginReviveHold()
	if reviveBusy or localDowned then
		return
	end
	local target = findNearestDownedTeammate()
	if target == nil then
		return
	end
	reviveTargetUserId = target
	reviveHoldStart = os.clock()
end

local function completeReviveHold()
	local target = reviveTargetUserId
	cancelReviveHold()
	if target == nil or reviveBusy then
		return
	end
	reviveBusy = true
	task.spawn(function()
		local ok, result = pcall(function()
			if requestReviveTeammate ~= nil then
				return requestReviveTeammate:InvokeServer(target)
			end
			return nil
		end)
		if not ok then
			warn(`[InputController] revive invoke failed: {result}`)
		elseif type(result) == "table" and result.ok ~= true and result.err ~= nil then
			warn(`[InputController] revive rejected: {result.err}`)
		end
		reviveBusy = false
	end)
end

local function onReviveAction(_actionName: string, inputState: Enum.UserInputState, _input: InputObject)
	if inputState == Enum.UserInputState.Begin then
		beginReviveHold()
		return Enum.ContextActionResult.Sink
	elseif inputState == Enum.UserInputState.End or inputState == Enum.UserInputState.Cancel then
		cancelReviveHold()
		return Enum.ContextActionResult.Sink
	end
	return Enum.ContextActionResult.Pass
end

--------------------------------------------------------------------------------
-- Per-frame: revive hold progress + throttled contextual button refresh
--------------------------------------------------------------------------------

local contextAccumulator = 0

local function refreshContextButtons()
	-- Grab/Drop context.
	local nearestUid = findNearestCase()
	local carriedCount = getCarriedCount()
	local canGrab = nearestUid ~= nil and carriedCount < maxCarry
	local canDrop = carriedCount > 0
	ContextActionService:SetTitle(ACTION_GRAB_DROP, if canGrab then "GRAB" else "DROP")
	setButtonLook(ACTION_GRAB_DROP, (canGrab or canDrop) and not localDowned and not grabBusy)

	-- Revive context.
	local hasReviveTarget = findNearestDownedTeammate() ~= nil
	setButtonLook(ACTION_REVIVE, hasReviveTarget and not localDowned and not reviveBusy)

	-- Sprint reflects toggle state.
	setButtonLook(ACTION_SPRINT, not localDowned, if sprinting then COLOR_SPRINT_ON else COLOR_ENABLED)
end

local function onHeartbeat(deltaTime: number)
	-- Revive hold ring (every frame for smoothness).
	local holdStart = reviveHoldStart
	local target = reviveTargetUserId
	if holdStart ~= nil and target ~= nil then
		-- Target must stay downed and in range for the whole hold.
		if downedTeammates[target] == nil or downedTeammateDistance(target) > REVIVE_RANGE_STUDS then
			cancelReviveHold()
		else
			local progress = (os.clock() - holdStart) / GameConstants.REVIVE_HOLD_SECONDS
			if progress >= 1 then
				setHoldProgress(1)
				completeReviveHold()
			else
				setHoldProgress(progress)
			end
		end
	end

	-- Contextual button refresh (throttled).
	contextAccumulator += deltaTime
	if contextAccumulator >= CONTEXT_POLL_SECONDS then
		contextAccumulator = 0
		refreshContextButtons()
		-- Sprint composes with the server: CaseService.ApplyCarrySpeed writes
		-- Humanoid.WalkSpeed on pickup/drop and that property replicates down,
		-- stomping a client-side sprint. Re-asserting the expected speed here
		-- (idempotent write, 0.15s cadence) keeps the two from fighting; the
		-- server separately validates actual velocity against the sprint cap.
		applyWalkSpeed()
	end
end

--------------------------------------------------------------------------------
-- Remote listeners
--------------------------------------------------------------------------------

local function onPlayerDownedState(payload: any)
	if type(payload) ~= "table" or type(payload.userId) ~= "number" then
		return
	end
	if payload.userId == LocalPlayer.UserId then
		localDowned = payload.downed == true
		if localDowned then
			setSprinting(false)
			cancelReviveHold()
		else
			applyWalkSpeed()
		end
		return
	end
	if payload.downed == true then
		local position: Vector3? = nil
		if type(payload.position) == "table" and #payload.position >= 3 then
			position = Vector3.new(payload.position[1], payload.position[2], payload.position[3])
		end
		downedTeammates[payload.userId] = position
	else
		downedTeammates[payload.userId] = nil
		if reviveTargetUserId == payload.userId then
			cancelReviveHold()
		end
	end
end

local function onNoiseMeter(payload: any)
	if type(payload) == "table" and type(payload.maxCarry) == "number" then
		maxCarry = payload.maxCarry
	end
end

--------------------------------------------------------------------------------
-- Public API (via Controllers.Get("InputController"))
--------------------------------------------------------------------------------

function InputController.IsSprinting(): boolean
	return sprinting
end

function InputController.GetSprintChangedSignal(): RBXScriptSignal
	return sprintChanged.Event
end

-- 0..1 while the revive hold is in progress (RunHUD/others may mirror it).
function InputController.GetReviveProgress(): number
	return reviveProgress
end

function InputController.GetMaxCarry(): number
	return maxCarry
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function InputController:Init(registry: any)
	registryRef = registry
end

function InputController:Start()
	if registryRef ~= nil and type(registryRef.Get) == "function" then
		carryController = registryRef.Get("CarryController")
	end

	-- Movement: default Roblox dynamic thumbstick (SOP §3.2 one-thumb spec) —
	-- engine default, nothing to set. Dev* Player properties are
	-- server-authoritative and a LocalScript write only spams a permission
	-- warning (use StarterPlayer.DevTouchMovementMode if it ever needs forcing).

	-- Resolve remotes (yields until replicated — Start may yield, Init may not).
	requestPickupCase = Remotes.GetFunction("RequestPickupCase")
	requestDropCase = Remotes.GetFunction("RequestDropCase")
	requestReviveTeammate = Remotes.GetFunction("RequestReviveTeammate")
	requestAttack = Remotes.GetFunction("Combat.Attack")
	consumableUse = Remotes.GetFunction("Consumable.Use")
	shopGetCatalog = Remotes.GetFunction("Shop.GetCatalog")
	local playerDownedState = Remotes.GetEvent("PlayerDownedState")
	local noiseMeter = Remotes.GetEvent("NoiseMeter")
	local funnelClient = Remotes.GetEvent("FunnelClient")

	playerDownedState.OnClientEvent:Connect(onPlayerDownedState)
	noiseMeter.OnClientEvent:Connect(onNoiseMeter)

	-- A downed teammate who disconnects never broadcasts downed=false — clear
	-- the entry locally so revive/steal gating never targets a ghost (or that
	-- user's healthy rejoined character).
	Players.PlayerRemoving:Connect(function(player)
		if downedTeammates[player.UserId] ~= nil then
			downedTeammates[player.UserId] = nil
			if reviveTargetUserId == player.UserId then
				cancelReviveHold()
			end
		end
	end)

	buildHoldGui()

	-- Bind actions: keyboard + (on touch devices) right-side CAS buttons.
	local touch = UserInputService.TouchEnabled
	ContextActionService:BindAction(ACTION_SPRINT, onSprintAction, touch, Enum.KeyCode.LeftShift)
	ContextActionService:BindAction(ACTION_GRAB_DROP, onGrabDropAction, touch, Enum.KeyCode.E)
	ContextActionService:BindAction(ACTION_REVIVE, onReviveAction, touch, Enum.KeyCode.F)
	ContextActionService:BindAction(ACTION_ATTACK, onAttackAction, touch, Enum.KeyCode.Q)
	ContextActionService:BindAction(ACTION_EXIT_WARP, onExitWarpAction, touch, Enum.KeyCode.T)

	ContextActionService:SetTitle(ACTION_SPRINT, "SPRINT")
	ContextActionService:SetTitle(ACTION_GRAB_DROP, "GRAB")
	ContextActionService:SetTitle(ACTION_REVIVE, "REVIVE")
	ContextActionService:SetTitle(ACTION_ATTACK, "FIGHT")
	ContextActionService:SetTitle(ACTION_EXIT_WARP, "WARP")

	-- Cluster on the right, around the jump button, all reachable by one thumb.
	styleButton(ACTION_GRAB_DROP, GRAB_BUTTON_PX, UDim2.fromScale(0.22, 0.52))
	styleButton(ACTION_SPRINT, SPRINT_BUTTON_PX, UDim2.fromScale(0.56, 0.34))
	styleButton(ACTION_REVIVE, REVIVE_BUTTON_PX, UDim2.fromScale(0.84, 0.1))
	styleButton(ACTION_ATTACK, ATTACK_BUTTON_PX, UDim2.fromScale(0.56, 0.72))
	styleButton(ACTION_EXIT_WARP, ATTACK_BUTTON_PX, UDim2.fromScale(0.84, 0.86))
	refreshContextButtons()

	-- Re-apply walk speed when the character (re)spawns or the carry stack
	-- changes (CARRY_SPEED_MULT_PER_CASE is part of the greed dial).
	LocalPlayer.CharacterAdded:Connect(function()
		setSprinting(false)
		task.defer(applyWalkSpeed)
	end)
	if carryController ~= nil and type(carryController.GetCarriedChangedSignal) == "function" then
		carryController.GetCarriedChangedSignal():Connect(function(userId: number)
			if userId == LocalPlayer.UserId then
				applyWalkSpeed()
			end
		end)
	end
	-- Equipping a speed pet changes "PetSpeedBonus": re-settle WalkSpeed at once.
	LocalPlayer:GetAttributeChangedSignal("PetSpeedBonus"):Connect(applyWalkSpeed)
	-- Mount/dismount flips the server-set "BikeActive" mirror (BikeService,
	-- R3-5): re-settle immediately so this client WalkSpeed owner agrees with
	-- the server owner's ApplyCarrySpeed re-settle — max(bike, sprint), never
	-- stacked.
	LocalPlayer:GetAttributeChangedSignal("BikeActive"):Connect(applyWalkSpeed)

	RunService.Heartbeat:Connect(onHeartbeat)

	-- Controls are live: report CoreLoop funnel step 1 (§H).
	funnelClient:FireServer({ event = "client_spawn_ready" })
end

return InputController
