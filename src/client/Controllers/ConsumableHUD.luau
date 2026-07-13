--!strict
-- CRYPTLINGS: NIGHT SHIFT — ConsumableHUD (Stage 6 "Monetization wiring";
-- SOP §4.1 launch scope, §4.2 effects; module consumables-gameplay).
-- Contextual one-thumb consumable chips with owned counts, mobile-first
-- (§3.2: touch targets >= 44px, viewport-driven UIScale, safe-area insets):
--   * SPRAY chip  — visible in the hub/intermission and during a run; grayed
--                   while the spray is already active or when count == 0.
--   * BEACON      — a big self-revive button shown ONLY while downed (it sits
--                   under RunHUD's bleedout ring, replacing the wait-for-help
--                   ask with the paid out).
--   * KEY chip    — appears when a tagged "VaultDoor" is near, pulses inside
--                   the server's 8-stud use range.
-- Every chip at count == 0 deep-links to the shop (ShopUI.OpenTo(sku) via a
-- safe registry lookup — ShopUI is a parallel Stage 6 module).
--
-- Owned counts (documented hack kept inside the two consumables-gameplay
-- files): seeded by a synthetic ShopGrant {sku = "_SYNC", summary = JSON
-- counts} that ConsumableService pushes on profile load and again on
-- client_spawn_ready; after that, counts track real ShopGrant pushes (via the
-- shared ProductCatalog grant specs) and the authoritative `remaining` in
-- every Consumable.Use reply.

local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConstants = require(Shared:WaitForChild("Config"):WaitForChild("GameConstants"))
local Remotes = require(Shared:WaitForChild("Net"):WaitForChild("Remotes"))
local ProductCatalog = require(Shared:WaitForChild("Economy"):WaitForChild("ProductCatalog"))

local LocalPlayer = Players.LocalPlayer

--------------------------------------------------------------------------------
-- HUD tuning (cosmetic, this module's domain)
--------------------------------------------------------------------------------

local TAG_VAULT_DOOR = "VaultDoor"
-- The server validates the key against this same constant (§G: promoted so the
-- pulse range and ConsumableService's TOO_FAR check can never diverge).
local VAULT_USE_RANGE_STUDS = GameConstants.VAULT_KEY_RANGE_STUDS
local VAULT_CHIP_VISIBLE_RANGE_STUDS = 30 -- chip appears (dim) inside this
local VAULT_POLL_SECONDS = 0.25

-- Same design-space scaling as RunHUD (450px short axis, clamped).
local DESIGN_SHORT_AXIS_PX = 450
local UISCALE_MIN = 0.85
local UISCALE_MAX = 1.6

local CHIP_WIDTH_PX = 132
local CHIP_HEIGHT_PX = 48 -- >= MOBILE_MIN_TOUCH_TARGET_PX (§G)

local COLOR_PANEL = Color3.fromRGB(18, 20, 24)
local COLOR_TEXT = Color3.fromRGB(235, 238, 240)
local COLOR_TEXT_DIM = Color3.fromRGB(160, 166, 172)
local COLOR_SPRAY = Color3.fromRGB(85, 170, 85)
local COLOR_BEACON = Color3.fromRGB(110, 220, 120)
local COLOR_KEY = Color3.fromRGB(235, 190, 52)
local COLOR_BADGE = Color3.fromRGB(60, 64, 70)

-- kind -> Price Ladder sku (shop deep-link target).
local KIND_TO_SKU: { [string]: string } = {
	scentSpray = "SCENT_SPRAY",
	reviveBeacon = "REVIVE_BEACON",
	foremansKey = "FOREMANS_KEY",
}

local SYNC_SKU = "_SYNC"

-- Server error -> player-facing toast copy.
local ERR_TEXT: { [string]: string } = {
	NONE_OWNED = "NONE LEFT — RESTOCK IN THE SHOP",
	ALREADY_ACTIVE = "SPRAY ALREADY ACTIVE THIS RUN",
	NOT_DOWNED = "BEACON ONLY WORKS WHILE YOU'RE DOWN",
	TOO_FAR = "GET CLOSER TO THE VAULT DOOR",
	ALREADY_USED = "VAULT ALREADY CRACKED THIS SHIFT",
	NO_VAULT = "NO VAULT ON THIS FLOOR",
	WRONG_CONTEXT = "CAN'T USE THAT RIGHT NOW",
	BUSY = "HOLD ON...",
	NOT_LOADED = "STILL LOADING YOUR LOCKER...",
	FAILED = "SOMETHING JAMMED — TRY AGAIN",
}

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local ConsumableHUD = {}

local registryRef: any = nil

local counts: { [string]: number } = { scentSpray = 0, reviveBeacon = 0, foremansKey = 0 }
local seeded = false -- first _SYNC arrived

local shiftStateName = "Intermission"
local localDowned = false
local sprayActiveLocal = false
local useBusy = false

local vaultDistance = math.huge
local nextVaultPollAt = 0

local consumableUse: RemoteFunction? = nil

type Chip = {
	button: TextButton,
	countBadge: TextLabel,
	label: TextLabel,
	accent: Color3,
}

local uiScale: UIScale? = nil
local chips: { [string]: Chip } = {}
local beaconButton: TextButton? = nil
local keyPulseScale: UIScale? = nil

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function toast(text: string)
	if registryRef == nil or type(registryRef.Get) ~= "function" then
		return
	end
	local runHud = registryRef.Get("RunHUD")
	if runHud ~= nil and type(runHud.ShowToast) == "function" then
		pcall(runHud.ShowToast, text, 3)
	end
end

-- Deep-link to the shop, pre-scrolled to this sku (safe registry lookup —
-- ShopUI is a parallel Stage 6 module and may be absent in a partial build).
local function openShopTo(sku: string)
	if registryRef ~= nil and type(registryRef.Get) == "function" then
		local shopUi = registryRef.Get("ShopUI")
		if shopUi ~= nil then
			for _, methodName in { "OpenTo", "Open", "Show" } do
				if type(shopUi[methodName]) == "function" then
					local ok = pcall(shopUi[methodName], sku)
					if ok then
						return
					end
				end
			end
		end
	end
	toast("RESTOCK AT THE SUPPLY SHOP IN THE HUB")
end

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

--------------------------------------------------------------------------------
-- Gui construction
--------------------------------------------------------------------------------

local function makeRound(parent: GuiObject, radius: number)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius)
	corner.Parent = parent
end

local function buildChip(parent: Instance, name: string, labelText: string, accent: Color3, order: number): Chip
	local button = Instance.new("TextButton")
	button.Name = name
	button.LayoutOrder = order
	button.Size = UDim2.fromOffset(CHIP_WIDTH_PX, CHIP_HEIGHT_PX)
	button.BackgroundColor3 = COLOR_PANEL
	button.BackgroundTransparency = 0.2
	button.BorderSizePixel = 0
	button.Text = ""
	button.AutoButtonColor = true
	button.Visible = false
	button.Parent = parent
	makeRound(button, 10)

	local stripe = Instance.new("Frame")
	stripe.Name = "Accent"
	stripe.Size = UDim2.new(0, 5, 1, 0)
	stripe.BackgroundColor3 = accent
	stripe.BorderSizePixel = 0
	stripe.Parent = button
	makeRound(stripe, 3)

	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.Position = UDim2.fromOffset(13, 0)
	label.Size = UDim2.new(1, -44, 1, 0)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextSize = 14
	label.TextColor3 = COLOR_TEXT
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Text = labelText
	label.Parent = button

	local badge = Instance.new("TextLabel")
	badge.Name = "Count"
	badge.AnchorPoint = Vector2.new(1, 0.5)
	badge.Position = UDim2.new(1, -7, 0.5, 0)
	badge.Size = UDim2.fromOffset(26, 26)
	badge.BackgroundColor3 = COLOR_BADGE
	badge.BackgroundTransparency = 0.2
	badge.BorderSizePixel = 0
	badge.Font = Enum.Font.GothamBold
	badge.TextSize = 14
	badge.TextColor3 = COLOR_TEXT
	badge.Text = "0"
	badge.Parent = button
	local badgeCorner = Instance.new("UICorner")
	badgeCorner.CornerRadius = UDim.new(1, 0)
	badgeCorner.Parent = badge

	return { button = button, countBadge = badge, label = label, accent = accent }
end

local function buildGui(): ScreenGui
	local gui = Instance.new("ScreenGui")
	gui.Name = "ConsumableHUD"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = false
	gui.ScreenInsets = Enum.ScreenInsets.DeviceSafeInsets
	gui.DisplayOrder = 15 -- above RunHUD panels, below its toasts/banner pops

	local root = Instance.new("Frame")
	root.Name = "Root"
	root.Size = UDim2.fromScale(1, 1)
	root.BackgroundTransparency = 1
	root.Parent = gui

	local scale = Instance.new("UIScale")
	scale.Parent = root
	uiScale = scale

	-- Left-edge chip column, above the dynamic thumbstick zone: one-thumb
	-- reachable without covering movement (left thumb taps up, not across).
	local column = Instance.new("Frame")
	column.Name = "Chips"
	column.AnchorPoint = Vector2.new(0, 1)
	column.Position = UDim2.new(0, 10, 1, -190)
	column.Size = UDim2.fromOffset(CHIP_WIDTH_PX, CHIP_HEIGHT_PX * 2 + 8)
	column.BackgroundTransparency = 1
	column.Parent = root
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.VerticalAlignment = Enum.VerticalAlignment.Bottom
	layout.Padding = UDim.new(0, 8)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = column

	chips.scentSpray = buildChip(column, "SprayChip", "STEADY GRIPS", COLOR_SPRAY, 1)
	chips.foremansKey = buildChip(column, "KeyChip", "FOREMAN'S KEY", COLOR_KEY, 2)

	local pulse = Instance.new("UIScale")
	pulse.Parent = chips.foremansKey.button
	keyPulseScale = pulse

	-- Beacon: a big one-thumb button shown only while downed, sitting under
	-- RunHUD's bleedout ring (the ring is at 0.42; this lands clear of the
	-- "YOU'RE DOWN" copy block at 0.62-0.69).
	local beacon = Instance.new("TextButton")
	beacon.Name = "BeaconButton"
	beacon.AnchorPoint = Vector2.new(0.5, 0.5)
	beacon.Position = UDim2.fromScale(0.5, 0.82)
	beacon.Size = UDim2.fromOffset(250, 56)
	beacon.BackgroundColor3 = COLOR_BEACON
	beacon.BorderSizePixel = 0
	beacon.Font = Enum.Font.GothamBold
	beacon.TextSize = 17
	beacon.TextColor3 = Color3.fromRGB(12, 24, 14)
	beacon.Text = "USE REVIVE BEACON"
	beacon.Visible = false
	beacon.ZIndex = 12 -- above RunHUD's downed overlay (ZIndex 5-7, DisplayOrder 10)
	beacon.Parent = root
	makeRound(beacon, 12)
	beaconButton = beacon

	return gui
end

local function updateScale()
	local camera = workspace.CurrentCamera
	if camera == nil or uiScale == nil then
		return
	end
	local viewport = camera.ViewportSize
	local shortAxis = math.min(viewport.X, viewport.Y)
	if shortAxis <= 0 then
		return
	end
	uiScale.Scale = math.clamp(shortAxis / DESIGN_SHORT_AXIS_PX, UISCALE_MIN, UISCALE_MAX)
end

--------------------------------------------------------------------------------
-- Chip refresh (contextual visibility + owned-count styling)
--------------------------------------------------------------------------------

local function styleChip(chip: Chip, enabled: boolean, count: number, labelText: string)
	chip.label.Text = labelText
	chip.countBadge.Text = tostring(count)
	chip.countBadge.BackgroundColor3 = if count > 0 then chip.accent else COLOR_BADGE
	chip.label.TextColor3 = if enabled then COLOR_TEXT else COLOR_TEXT_DIM
	chip.button.BackgroundTransparency = if enabled then 0.2 else 0.55
end

local function refreshChips()
	local sprayChip = chips.scentSpray
	local keyChip = chips.foremansKey

	-- SPRAY: hub/intermission or mid-run, never while downed (beacon owns that
	-- moment). Grayed when already active or out of stock; still tappable at 0
	-- for the shop deep-link.
	if sprayChip ~= nil then
		local inContext = (shiftStateName == "Intermission" or shiftStateName == "Active") and not localDowned
		sprayChip.button.Visible = inContext
		if inContext then
			local count = counts.scentSpray or 0
			if sprayActiveLocal then
				styleChip(sprayChip, false, count, "GRIPS ACTIVE")
			elseif count <= 0 then
				styleChip(sprayChip, false, 0, "BUY GRIPS")
			else
				styleChip(sprayChip, true, count, "STEADY GRIPS")
			end
		end
	end

	-- KEY: only mid-run near the vault door; pulses inside the 8-stud use range.
	if keyChip ~= nil then
		local nearVault = shiftStateName == "Active"
			and not localDowned
			and vaultDistance <= VAULT_CHIP_VISIBLE_RANGE_STUDS
		keyChip.button.Visible = nearVault
		if nearVault then
			local count = counts.foremansKey or 0
			local inRange = vaultDistance <= VAULT_USE_RANGE_STUDS
			if count <= 0 then
				styleChip(keyChip, false, 0, "BUY FOREMAN'S KEY")
			elseif inRange then
				styleChip(keyChip, true, count, "USE FOREMAN'S KEY")
			else
				styleChip(keyChip, false, count, "FOREMAN'S KEY")
			end
		end
	end

	-- BEACON: replaces the wait-for-a-teammate ask while downed.
	local beacon = beaconButton
	if beacon ~= nil then
		beacon.Visible = localDowned
		if localDowned then
			local count = counts.reviveBeacon or 0
			if count <= 0 then
				beacon.Text = "BUY REVIVE BEACON"
				beacon.BackgroundColor3 = COLOR_PANEL
				beacon.TextColor3 = COLOR_TEXT_DIM
			else
				beacon.Text = `USE REVIVE BEACON ({count})`
				beacon.BackgroundColor3 = COLOR_BEACON
				beacon.TextColor3 = Color3.fromRGB(12, 24, 14)
			end
		end
	end
end

--------------------------------------------------------------------------------
-- Use flow
--------------------------------------------------------------------------------

local function onUseSucceeded(kind: string)
	if kind == "scentSpray" then
		sprayActiveLocal = true
		toast("GRIPS STEADIED — CASES WON'T SLOW YOU THIS RUN")
	elseif kind == "reviveBeacon" then
		toast("BEACON FIRED — BACK ON YOUR FEET")
	elseif kind == "foremansKey" then
		toast("VAULT CRACKED — GRAB THE GOLD CASE")
	end
end

local function useConsumable(kind: string)
	local sku = KIND_TO_SKU[kind]
	if (counts[kind] or 0) <= 0 then
		openShopTo(sku) -- chip deep-links to the shop when out of stock
		return
	end
	if useBusy or consumableUse == nil then
		return
	end
	useBusy = true
	task.spawn(function()
		local ok, result = pcall(function()
			return (consumableUse :: RemoteFunction):InvokeServer(kind)
		end)
		if not ok then
			warn(`[ConsumableHUD] Consumable.Use invoke failed: {result}`)
		elseif type(result) == "table" then
			if type(result.remaining) == "number" then
				counts[kind] = math.max(math.floor(result.remaining), 0) -- authoritative
			end
			if result.ok == true then
				onUseSucceeded(kind)
			else
				local err = if type(result.err) == "string" then result.err else "FAILED"
				toast(ERR_TEXT[err] or ERR_TEXT.FAILED)
			end
		end
		useBusy = false
		refreshChips()
	end)
end

--------------------------------------------------------------------------------
-- Count tracking (the documented _SYNC + ShopGrant + Use-reply hack)
--------------------------------------------------------------------------------

local function applySyncSummary(summary: string)
	local ok, decoded = pcall(function()
		return HttpService:JSONDecode(summary)
	end)
	if not ok or type(decoded) ~= "table" then
		return
	end
	for kind in KIND_TO_SKU do
		local value = (decoded :: any)[kind]
		if type(value) == "number" then
			counts[kind] = math.max(math.floor(value), 0)
		end
	end
	seeded = true
end

local function onShopGrant(payload: any)
	if type(payload) ~= "table" or type(payload.sku) ~= "string" then
		return
	end
	if payload.sku == SYNC_SKU then
		if type(payload.summary) == "string" then
			applySyncSummary(payload.summary)
		end
	else
		-- Real purchase: bump counts from the shared grant spec. The next
		-- Use reply (or rejoin _SYNC) re-trues any drift.
		local product = ProductCatalog.Get(payload.sku)
		local granted = if product ~= nil then product.grants.consumables else nil
		if granted ~= nil then
			for kind, amount in granted do
				if KIND_TO_SKU[kind] ~= nil and type(amount) == "number" then
					counts[kind] = math.max((counts[kind] or 0) + math.floor(amount), 0)
				end
			end
		end
	end
	refreshChips()
end

--------------------------------------------------------------------------------
-- Remote handlers / polling
--------------------------------------------------------------------------------

local function onShiftState(payload: any)
	if type(payload) ~= "table" or type(payload.state) ~= "string" then
		return
	end
	shiftStateName = payload.state
	if shiftStateName ~= "Active" then
		-- Run over: the server resets the spray mult at the same boundary.
		sprayActiveLocal = false
		vaultDistance = math.huge
	end
	refreshChips()
end

local function onPlayerDownedState(payload: any)
	if type(payload) ~= "table" or payload.userId ~= LocalPlayer.UserId then
		return
	end
	localDowned = payload.downed == true
	refreshChips()
end

-- Nearest tagged VaultDoor distance (cheap: exactly one per floor).
local function pollVaultDistance()
	local root = getLocalRootPart()
	local best = math.huge
	if root ~= nil and shiftStateName == "Active" then
		for _, door in CollectionService:GetTagged(TAG_VAULT_DOOR) do
			if door:IsA("BasePart") and door:IsDescendantOf(workspace) then
				local distance = (door.Position - root.Position).Magnitude
				if distance < best then
					best = distance
				end
			end
		end
	end
	if best ~= vaultDistance then
		local wasVisible = vaultDistance <= VAULT_CHIP_VISIBLE_RANGE_STUDS
		local nowVisible = best <= VAULT_CHIP_VISIBLE_RANGE_STUDS
		local crossedUseRange = (vaultDistance <= VAULT_USE_RANGE_STUDS) ~= (best <= VAULT_USE_RANGE_STUDS)
		vaultDistance = best
		if wasVisible ~= nowVisible or crossedUseRange then
			refreshChips()
		end
	end
end

local function onHeartbeat()
	local now = os.clock()
	if now >= nextVaultPollAt then
		nextVaultPollAt = now + VAULT_POLL_SECONDS
		pollVaultDistance()
	end

	-- Key chip pulse while inside the use range with a key in pocket (§spec:
	-- "key chip pulses near vault door").
	local pulse = keyPulseScale
	if pulse ~= nil then
		local pulsing = vaultDistance <= VAULT_USE_RANGE_STUDS
			and (counts.foremansKey or 0) > 0
			and shiftStateName == "Active"
			and not localDowned
		pulse.Scale = if pulsing then 1 + 0.05 * math.sin(now * 7) else 1
	end
end

local function hookCharacter(character: Model)
	local humanoid = character:WaitForChild("Humanoid", 10)
	if humanoid ~= nil and humanoid:IsA("Humanoid") then
		humanoid.Died:Connect(function()
			sprayActiveLocal = false -- death ends the run; server resets the mult
			refreshChips()
		end)
	end
end

--------------------------------------------------------------------------------
-- Public API (via Controllers.Get("ConsumableHUD"))
--------------------------------------------------------------------------------

function ConsumableHUD.GetCounts(): { [string]: number }
	return table.clone(counts)
end

function ConsumableHUD.IsSprayActive(): boolean
	return sprayActiveLocal
end

function ConsumableHUD.IsSeeded(): boolean
	return seeded
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function ConsumableHUD:Init(registry: any)
	registryRef = registry
end

function ConsumableHUD:Start()
	local playerGui = LocalPlayer:WaitForChild("PlayerGui")
	local gui = buildGui()
	gui.Parent = playerGui

	updateScale()
	local camera = workspace.CurrentCamera
	if camera ~= nil then
		camera:GetPropertyChangedSignal("ViewportSize"):Connect(updateScale)
	end
	workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		local newCamera = workspace.CurrentCamera
		if newCamera ~= nil then
			newCamera:GetPropertyChangedSignal("ViewportSize"):Connect(updateScale)
			updateScale()
		end
	end)

	-- Remotes (Start may yield).
	consumableUse = Remotes.GetFunction("Consumable.Use")
	Remotes.GetEvent("ShopGrant").OnClientEvent:Connect(onShopGrant)
	Remotes.GetEvent("ShiftState").OnClientEvent:Connect(onShiftState)
	Remotes.GetEvent("PlayerDownedState").OnClientEvent:Connect(onPlayerDownedState)

	for kind, chip in chips do
		local chipKind = kind
		chip.button.Activated:Connect(function()
			useConsumable(chipKind)
		end)
	end
	local beacon = beaconButton
	if beacon ~= nil then
		beacon.Activated:Connect(function()
			useConsumable("reviveBeacon")
		end)
	end

	if LocalPlayer.Character ~= nil then
		task.spawn(hookCharacter, LocalPlayer.Character)
	end
	LocalPlayer.CharacterAdded:Connect(function(character)
		task.spawn(hookCharacter, character)
	end)

	refreshChips()
	RunService.Heartbeat:Connect(onHeartbeat)
end

return ConsumableHUD
