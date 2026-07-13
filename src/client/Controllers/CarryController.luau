--!strict
-- CRYPTLINGS: NIGHT SHIFT — CarryController (Stage 1, module mobile-run-ui).
-- Client-side view of who is carrying which cases, driven entirely by the
-- CaseEvent remote ({kind:"PickedUp"|"Dropped"|"Banked"|"Lost", caseUid, tier,
-- holderUserId?}, CONTRACTS v1 §B). Responsibilities:
--   * Tracks per-player carry stacks (the source the HUD chips and the
--     contextual Grab/Drop button read from).
--   * Renders every teammate's carried stack as greybox parts welded above
--     their character — the squad can SEE each other's greed.
--   * Local squirm audio: carried cases giggle/cry on a random 8-15s cadence
--     (placeholder rbxasset sounds) with volume scaling by carried count —
--     the §1.1 greed dial made audible. Purely cosmetic; the server's
--     NoiseService owns the real aggro model.
--
-- Public API (Controllers.Get("CarryController")):
--   GetCarried(userId) -> { {uid, tier} }   (copy)
--   GetLocalCarried()  -> { {uid, tier} }   (copy)
--   GetLocalCarriedUids() -> { string }     (oldest first)
--   GetLocalCount()    -> number
--   GetCarriedChangedSignal() -> RBXScriptSignal (fires holder userId)

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConstants = require(Shared:WaitForChild("Config"):WaitForChild("GameConstants"))
local RarityTable = require(Shared:WaitForChild("Config"):WaitForChild("RarityTable"))
local Remotes = require(Shared:WaitForChild("Net"):WaitForChild("Remotes"))

local LocalPlayer = Players.LocalPlayer

--------------------------------------------------------------------------------
-- Visual/audio tuning (cosmetic, this module's domain)
--------------------------------------------------------------------------------

local STACK_MODEL_NAME = "NS_CarryStack"
local STACK_PART_SIZE = Vector3.new(1.5, 1.1, 1.5)
local STACK_BASE_HEIGHT = 2.9 -- studs above HumanoidRootPart center
local STACK_STEP_HEIGHT = 1.2

-- Case tier -> chip/stack color. Reuses the §E rarity palette so tiers read
-- consistently with rarity everywhere: T1 = Common grey, T2 = Rare blue
-- (the baseline tier), T3 = Godly gold (the deep-floor vault tier).
local TIER_COLOR_KEYS: { [number]: string } =
	{ [1] = "Common", [2] = "Uncommon", [3] = "Rare", [4] = "Epic", [5] = "Legendary", [6] = "Mythical" }

-- Placeholder squirm voices (replaced by real Cryptling VO in the art pass).
-- NOT uuhhh.mp3 for the cry: that's the classic death "oof", and players read
-- the random squirms as a bug. Pitched water impact = wet box squirm instead.
local SQUIRM_GIGGLE_ID = "rbxasset://sounds/electronicpingshort.wav"
local SQUIRM_CRY_ID = "rbxasset://sounds/impact_water.mp3"
local SQUIRM_BASE_VOLUME = 0.12 -- per carried case; the greed dial, audible
local SQUIRM_MAX_VOLUME = 0.8

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

export type CarriedCase = {
	uid: string,
	tier: number,
	nextSquirmAt: number, -- os.clock deadline for this case's next squirm
}

local CarryController = {}

local stacks: { [number]: { CarriedCase } } = {} -- userId -> ordered carried cases
local holderByUid: { [string]: number } = {}

local carriedChanged = Instance.new("BindableEvent")

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function tierColor(tier: number): Color3
	local key = TIER_COLOR_KEYS[tier] or "Common"
	local color = (RarityTable.RARITY_COLORS :: any)[key]
	if typeof(color) == "Color3" then
		return color
	end
	return Color3.fromRGB(178, 178, 178)
end

local function nextSquirmDeadline(): number
	local span = GameConstants.SQUIRM_INTERVAL_MAX_SECONDS - GameConstants.SQUIRM_INTERVAL_MIN_SECONDS
	return os.clock() + GameConstants.SQUIRM_INTERVAL_MIN_SECONDS + math.random() * span
end

local function getCharacterRoot(userId: number): BasePart?
	local player = Players:GetPlayerByUserId(userId)
	if player == nil or player.Character == nil then
		return nil
	end
	local root = player.Character:FindFirstChild("HumanoidRootPart")
	if root ~= nil and root:IsA("BasePart") then
		return root
	end
	return nil
end

--------------------------------------------------------------------------------
-- Stack rendering (greybox parts welded above the holder's head)
--------------------------------------------------------------------------------

local function clearStackModel(character: Instance)
	local existing = character:FindFirstChild(STACK_MODEL_NAME)
	if existing ~= nil then
		existing:Destroy()
	end
end

local function renderStack(userId: number)
	local player = Players:GetPlayerByUserId(userId)
	local character = if player ~= nil then player.Character else nil
	if character == nil then
		return
	end
	clearStackModel(character)

	local stack = stacks[userId]
	if stack == nil or #stack == 0 then
		return
	end
	local root = getCharacterRoot(userId)
	if root == nil then
		return
	end

	local model = Instance.new("Model")
	model.Name = STACK_MODEL_NAME

	for index, carried in stack do
		local part = Instance.new("Part")
		part.Name = `Case_{carried.uid}`
		part.Size = STACK_PART_SIZE
		part.Color = tierColor(carried.tier)
		part.Material = Enum.Material.SmoothPlastic
		part.Anchored = false
		part.Massless = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.CastShadow = false
		part.CFrame = root.CFrame * CFrame.new(0, STACK_BASE_HEIGHT + (index - 1) * STACK_STEP_HEIGHT, 0)

		local weld = Instance.new("WeldConstraint")
		weld.Part0 = root
		weld.Part1 = part
		weld.Parent = part

		part.Parent = model
	end

	model.Parent = character
end

--------------------------------------------------------------------------------
-- Squirm audio (local, cosmetic; volume scales with the holder's greed)
--------------------------------------------------------------------------------

local function playSquirm(userId: number, carriedCount: number)
	local root = getCharacterRoot(userId)
	if root == nil then
		return
	end
	local isGiggle = math.random() < 0.5
	local soundName = if isGiggle then "NS_SquirmGiggle" else "NS_SquirmCry"
	local sound = root:FindFirstChild(soundName) :: Sound?
	if sound == nil then
		local newSound = Instance.new("Sound")
		newSound.Name = soundName
		newSound.SoundId = if isGiggle then SQUIRM_GIGGLE_ID else SQUIRM_CRY_ID
		newSound.RollOffMode = Enum.RollOffMode.InverseTapered
		newSound.RollOffMaxDistance = GameConstants.HEARING_RANGE_MAX
		newSound.Parent = root
		sound = newSound
	end
	local sureSound = sound :: Sound
	sureSound.Volume = math.clamp(SQUIRM_BASE_VOLUME * carriedCount, 0, SQUIRM_MAX_VOLUME)
	sureSound.PlaybackSpeed = 0.9 + math.random() * 0.35
	sureSound:Play()
end

local function onSquirmHeartbeat()
	local now = os.clock()
	for userId, stack in stacks do
		local count = #stack
		if count > 0 then
			for _, carried in stack do
				if now >= carried.nextSquirmAt then
					carried.nextSquirmAt = nextSquirmDeadline()
					playSquirm(userId, count)
				end
			end
		end
	end
end

--------------------------------------------------------------------------------
-- Carry-state mutations (CaseEvent is the single source of truth)
--------------------------------------------------------------------------------

local function removeCase(caseUid: string): number?
	local holder = holderByUid[caseUid]
	if holder == nil then
		return nil
	end
	holderByUid[caseUid] = nil
	local stack = stacks[holder]
	if stack ~= nil then
		for index, carried in stack do
			if carried.uid == caseUid then
				table.remove(stack, index)
				break
			end
		end
		if #stack == 0 then
			stacks[holder] = nil
		end
	end
	return holder
end

-- Returns the previous holder's userId (nil if the case was not carried), so
-- steal transfers can re-render the robbed holder too.
local function addCase(caseUid: string, tier: number, holderUserId: number): number?
	local previousHolder = removeCase(caseUid) -- safety: a case can only have one holder
	local stack = stacks[holderUserId]
	if stack == nil then
		stack = {}
		stacks[holderUserId] = stack
	end
	table.insert(stack, {
		uid = caseUid,
		tier = tier,
		nextSquirmAt = nextSquirmDeadline(),
	})
	holderByUid[caseUid] = holderUserId
	return previousHolder
end

local function onCaseEvent(payload: any)
	if type(payload) ~= "table" or type(payload.caseUid) ~= "string" then
		return
	end
	local kind = payload.kind
	if kind == "PickedUp" then
		if type(payload.holderUserId) == "number" and type(payload.tier) == "number" then
			local previousHolder = addCase(payload.caseUid, payload.tier, payload.holderUserId)
			renderStack(payload.holderUserId)
			carriedChanged:Fire(payload.holderUserId)
			-- Steal transfer: re-render/notify the robbed holder so their stack
			-- model and HUD don't keep showing the stolen case.
			if previousHolder ~= nil and previousHolder ~= payload.holderUserId then
				renderStack(previousHolder)
				carriedChanged:Fire(previousHolder)
			end
		end
	elseif kind == "Dropped" or kind == "Banked" or kind == "Lost" then
		local holder = removeCase(payload.caseUid)
		if holder ~= nil then
			renderStack(holder)
			carriedChanged:Fire(holder)
		end
	end
end

local function clearAll()
	local holders: { number } = {}
	for userId in stacks do
		table.insert(holders, userId)
	end
	table.clear(stacks)
	table.clear(holderByUid)
	for _, userId in holders do
		renderStack(userId)
		carriedChanged:Fire(userId)
	end
end

local function onShiftState(payload: any)
	-- A fresh shift always starts empty-handed; Intermission resets the floor,
	-- and Complete means every un-banked case is already lost server-side.
	if type(payload) == "table" and (payload.state == "Intermission" or payload.state == "Complete") then
		clearAll()
	end
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

function CarryController.GetCarried(userId: number): { { uid: string, tier: number } }
	local result = {}
	local stack = stacks[userId]
	if stack ~= nil then
		for _, carried in stack do
			table.insert(result, { uid = carried.uid, tier = carried.tier })
		end
	end
	return result
end

function CarryController.GetLocalCarried(): { { uid: string, tier: number } }
	return CarryController.GetCarried(LocalPlayer.UserId)
end

function CarryController.GetLocalCarriedUids(): { string }
	local uids = {}
	local stack = stacks[LocalPlayer.UserId]
	if stack ~= nil then
		for _, carried in stack do
			table.insert(uids, carried.uid)
		end
	end
	return uids
end

function CarryController.GetLocalCount(): number
	local stack = stacks[LocalPlayer.UserId]
	return if stack ~= nil then #stack else 0
end

function CarryController.GetCarriedChangedSignal(): RBXScriptSignal
	return carriedChanged.Event
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function CarryController:Init(_registry: any)
	-- No registry dependencies; CaseEvent drives everything.
end

function CarryController:Start()
	local caseEvent = Remotes.GetEvent("CaseEvent")
	local shiftState = Remotes.GetEvent("ShiftState")

	caseEvent.OnClientEvent:Connect(onCaseEvent)
	shiftState.OnClientEvent:Connect(onShiftState)

	-- Re-render stacks when characters (re)spawn; a respawned character has no
	-- stack parts (they died with the old character).
	local function hookPlayer(player: Player)
		player.CharacterAdded:Connect(function()
			task.defer(renderStack, player.UserId)
		end)
	end
	for _, player in Players:GetPlayers() do
		hookPlayer(player)
	end
	Players.PlayerAdded:Connect(hookPlayer)
	Players.PlayerRemoving:Connect(function(player)
		local stack = stacks[player.UserId]
		if stack ~= nil then
			for _, carried in stack do
				holderByUid[carried.uid] = nil
			end
			stacks[player.UserId] = nil
		end
	end)

	-- Squirm scheduler (cheap: a few comparisons per frame for <= ~20 cases).
	RunService.Heartbeat:Connect(onSquirmHeartbeat)
end

return CarryController
