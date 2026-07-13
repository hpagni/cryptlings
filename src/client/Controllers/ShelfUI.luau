--!strict
-- CRYPTLINGS: NIGHT SHIFT — ShelfUI (Stage 5, module shelf-ui).
-- Collection-display UI for the walkable shelf rooms off the hub corridor
-- (SOP §3.1 ⑤, §1.2 session-to-session loop, §3.2 friend-visitable hubs).
--
--   * OWNER EDIT MODE (your own room only): slot pads get a client-local
--     ProximityPrompt (single tap on touch). Empty slot -> bottom-sheet picker:
--     grid of OWNED Cryptlings (ViewportFrame greybox thumbnails straight from
--     RarityTable recipes, rarity-colored frames, owned-count badges, "DUPE"
--     tag when count > 1 — the trade nudge), with already-fully-displayed ids
--     dimmed. Tap a card -> Shelf.Place. Occupied slot -> "Swap / Remove"
--     sheet -> Shelf.Place (overwrite) / Shelf.Remove. All edits are
--     OPTIMISTIC: the local view updates immediately, then reconciles against
--     the RemoteFunction reply (revert + toast on failure) and the
--     authoritative ShelfChanged broadcast.
--   * VISITOR MODE (anyone's room): every displayed Cryptling carries a
--     tappable BillboardGui hotspot. In someone else's room it opens a
--     READ-ONLY card — name, rarity in rarity color, "N of 12 — Factory Floor
--     Misfits" — with zero edit affordances. In your own room the same hotspot
--     routes to the Swap / Remove sheet.
--   * NO ENTRANCE RENDERING: the room-entrance completion strip was removed
--     in Addendum 2 R3-6 — entrance anchors remain tagged server-side but
--     ShelfUI no longer renders on them. In-room progress reads live on the
--     per-figure visitor card only.
--
-- 3D contract consumed (produced by the Stage 5 shelf-room generator; this
-- module never builds room geometry):
--   * Slot pads:   BasePart tag "ShelfSlotPad",  attrs OwnerUserId:number, SlotId:string,
--                  optional SlotLabel:string (pretty name for sheet titles).
--   * Displays:    Model|BasePart tag "ShelfDisplay", attrs OwnerUserId:number,
--                  SlotId:string, CryptlingId:string. Re-rendered from ShelfChanged.
--   * Entrances:   entrance anchors remain tagged server-side but ShelfUI no
--                  longer renders on them (Addendum 2 R3-6).
-- All discovery is CollectionService + attribute signals, so room build order
-- never matters. Everything this module creates lives in PlayerGui (client-
-- local prompts/billboards) — it never mutates the room parts themselves.
--
-- Mobile-first (SOP §3.2 / CONTRACTS §G): one-thumb bottom sheets, every
-- interactive target >= MOBILE_MIN_TOUCH_TARGET_PX, portrait-safe widths.
--
-- Public API (Controllers.Get("ShelfUI")):
--   ShelfUI.OpenSlotSheet(slotId)                 -- owner: picker or Swap/Remove by occupancy
--   ShelfUI.OpenVisitorCard(ownerUserId, cryptlingId)
--   ShelfUI.Close()
--   ShelfUI.IsOpen() -> boolean
--   ShelfUI.GetKnownShelf(ownerUserId) -> {[slotId]: string}? -- last ShelfChanged view

local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConstants = require(Shared:WaitForChild("Config"):WaitForChild("GameConstants"))
local RarityTable = require(Shared:WaitForChild("Config"):WaitForChild("RarityTable"))
local Remotes = require(Shared:WaitForChild("Net"):WaitForChild("Remotes"))

local LocalPlayer = Players.LocalPlayer

--------------------------------------------------------------------------------
-- Tuning (cosmetic, this module's domain)
--------------------------------------------------------------------------------

-- 3D discovery contract (see header).
local TAG_SLOT_PAD = "ShelfSlotPad"
local TAG_DISPLAY = "ShelfDisplay"
local ATTR_OWNER_USER_ID = "OwnerUserId"
local ATTR_SLOT_ID = "SlotId"
local ATTR_SLOT_LABEL = "SlotLabel"
local ATTR_CRYPTLING_ID = "CryptlingId"

-- Collection channel of record: PlayerDataService publishes every player's
-- {[cryptlingId]: count} as this JSON player attribute (Stage 4 decision,
-- consumed read-only here — same channel TradeUI's picker reads).
local ATTR_COLLECTION = "TradeCollection"

-- Touch sizing: every interactive target >= the §G mobile gate.
local MIN_TOUCH_PX = GameConstants.MOBILE_MIN_TOUCH_TARGET_PX -- 44
local CLOSE_PX = math.max(MIN_TOUCH_PX, 48)
local BUTTON_HEIGHT_PX = math.max(MIN_TOUCH_PX, 52)

-- Bottom sheet (one-thumb, §3.2): rises from the bottom edge, capped on
-- desktop so the grid never sprawls wider than a thumb-sweep.
local SHEET_HEIGHT_SCALE = 0.62
local SHEET_MIN_HEIGHT_PX = 320
local SHEET_MAX_WIDTH_PX = 720
local SHEET_SLIDE_SECONDS = 0.16

-- Picker grid cards.
local CARD_WIDTH_PX = 108
local CARD_HEIGHT_PX = 150
local GRID_GAP_PX = 8

-- Prompts / billboards.
local PROMPT_DISTANCE = 10
local HOTSPOT_MAX_DISTANCE = 45

local INVOKE_TIMEOUT_SECONDS = 8
-- Safety valve: optimistic edits that never see a reply OR a ShelfChanged are
-- dropped after this long so the sheet can't show stale state forever.
local OPTIMISTIC_TTL_SECONDS = 10

local TOAST_SECONDS = 2.4

-- ShelfService err codes -> player-readable toast copy (unknown codes fall
-- through raw so a new server code is still diagnosable in playtests).
local ERR_COPY: { [string]: string } = {
	TIMEOUT = "the server didn't answer in time",
	NOT_LOADED = "your data is still loading",
	BAD_SLOT = "that slot doesn't exist",
	TIER_LOCKED = "that display slot needs a bigger house — see the Shop",
	UNKNOWN_CRYPTLING = "that Pet doesn't exist",
	NOT_OWNED = "no undisplayed copy left to show",
	INTERNAL = "something went wrong, try again",
}

local function errCopy(err: string?): string
	if err == nil then
		return "try again"
	end
	return ERR_COPY[err] or err
end

-- Greybox palette (matches the hub UI family).
local COLOR_BACKDROP = Color3.fromRGB(8, 8, 10)
local COLOR_SHEET = Color3.fromRGB(34, 32, 38)
local COLOR_PANEL = Color3.fromRGB(46, 44, 52)
local COLOR_PANEL_DIM = Color3.fromRGB(40, 38, 45)
local COLOR_TEXT = Color3.fromRGB(235, 232, 228)
local COLOR_TEXT_DIM = Color3.fromRGB(162, 158, 154)
local COLOR_GOLD = Color3.fromRGB(235, 190, 52)
local COLOR_DANGER = Color3.fromRGB(204, 84, 70)
local COLOR_CONFIRM = Color3.fromRGB(85, 170, 85)
local COLOR_RARITY_FALLBACK = Color3.fromRGB(178, 178, 178)

local FONT = Enum.Font.GothamMedium
local FONT_BOLD = Enum.Font.GothamBold

--------------------------------------------------------------------------------
-- Roster (CONTRACTS §E) — in-pool ids drive the "N of 12" copy
--------------------------------------------------------------------------------

local POOL_IDS: { string } = {}
local POOL_INDEX: { [string]: number } = {}
for _, def in RarityTable.CRYPTLINGS :: { any } do
	if def.notInPool ~= true then
		table.insert(POOL_IDS, def.id)
		POOL_INDEX[def.id] = #POOL_IDS
	end
end
local POOL_SIZE = #POOL_IDS -- 12

local RARITY_RANK: { [string]: number } = {}
for index, rarity in RarityTable.RARITY_ORDER :: { string } do
	RARITY_RANK[rarity] = index
end

local ROSTER_ORDER: { [string]: number } = {}
for index, def in RarityTable.CRYPTLINGS :: { any } do
	ROSTER_ORDER[def.id] = index
end

local function rarityColor(rarity: string?): Color3
	local color = if rarity ~= nil then (RarityTable.RARITY_COLORS :: any)[rarity] else nil
	return if typeof(color) == "Color3" then color else COLOR_RARITY_FALLBACK
end

local function cryptlingDisplayName(cryptlingId: string): string
	local def = RarityTable.GetCryptling(cryptlingId)
	if type(def) == "table" and type(def.name) == "string" then
		return def.name
	end
	return cryptlingId
end

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

type SheetMode = "picker" | "occupied" | "visitor"
type SheetRequest = {
	mode: SheetMode,
	slotId: string?, -- picker / occupied
	slotLabel: string?,
	ownerUserId: number?, -- visitor
	cryptlingId: string?, -- occupied / visitor
}

type PadEntry = { prompt: ProximityPrompt?, conns: { RBXScriptConnection } }
type HotspotEntry = { gui: BillboardGui, button: TextButton, stroke: UIStroke, conns: { RBXScriptConnection } }

local ShelfUI = {}

local registryRef: any = nil

-- Last authoritative ShelfChanged view per owner.
local serverShelves: { [number]: { [string]: string } } = {}
-- Optimistic overlay for the LOCAL player's shelf: cryptlingId = place intent,
-- false = remove intent. Cleared by reply failure, ShelfChanged confirmation,
-- or the TTL valve.
local optimistic: { [string]: string | false } = {}
local optimisticStamp: { [string]: number } = {}

local pads: { [Instance]: PadEntry } = {}
local hotspots: { [Instance]: HotspotEntry } = {}

local screenGui: ScreenGui? = nil
local worldGuiFolder: Folder? = nil
local backdrop: TextButton? = nil
local sheetFrame: Frame? = nil
local sheetTitle: TextLabel? = nil
local sheetContent: Frame? = nil
local toastLabel: TextLabel? = nil
local toastToken = 0

local currentSheet: SheetRequest? = nil
local sheetOpen = false
local renderSheet: () -> () -- forward-declared

-- First-person cursor release (R4-2): the token is held while the bottom
-- sheet (slot sheet / visitor card) is up; Close is the single hide funnel
-- (onShiftState force-close routes through it too). Registry lookup,
-- nil-guarded: a missing CursorUnlock degrades to a no-op.
local CURSOR_TOKEN = "ShelfUI"

local function setCursorReleased(released: boolean)
	if registryRef == nil or type(registryRef.Get) ~= "function" then
		return
	end
	local cursorUnlock = registryRef.Get("CursorUnlock")
	if cursorUnlock == nil then
		return
	end
	if released then
		cursorUnlock.acquire(CURSOR_TOKEN)
	else
		cursorUnlock.release(CURSOR_TOKEN)
	end
end

--------------------------------------------------------------------------------
-- Collection + shelf views
--------------------------------------------------------------------------------

-- Decodes a player's published collection attribute -> {[cryptlingId]: count}.
local function readCollection(player: Player?): { [string]: number }?
	if player == nil then
		return nil
	end
	local raw = player:GetAttribute(ATTR_COLLECTION)
	if type(raw) ~= "string" or raw == "" then
		return nil
	end
	local ok, decoded = pcall(function()
		return HttpService:JSONDecode(raw)
	end)
	if not ok or type(decoded) ~= "table" then
		return nil
	end
	local counts: { [string]: number } = {}
	for id, count in decoded :: { [any]: any } do
		if type(id) == "string" and type(count) == "number" and count > 0 then
			counts[id] = math.floor(count)
		end
	end
	return counts
end

local function myCollection(): { [string]: number }?
	return readCollection(LocalPlayer)
end

-- The local player's shelf as the user should see it RIGHT NOW: last server
-- state with in-flight optimistic edits applied on top.
local function effectiveOwnSlots(): { [string]: string }
	local merged: { [string]: string } = {}
	local base = serverShelves[LocalPlayer.UserId]
	if base ~= nil then
		for slotId, cryptlingId in base do
			merged[slotId] = cryptlingId
		end
	end
	local now = os.clock()
	for slotId, intent in optimistic do
		local stamp = optimisticStamp[slotId]
		if stamp ~= nil and now - stamp > OPTIMISTIC_TTL_SECONDS then
			optimistic[slotId] = nil
			optimisticStamp[slotId] = nil
		elseif intent == false then
			merged[slotId] = nil
		else
			merged[slotId] = intent :: string
		end
	end
	return merged
end

local function displayedCount(cryptlingId: string): number
	local total = 0
	for _, displayed in effectiveOwnSlots() do
		if displayed == cryptlingId then
			total += 1
		end
	end
	return total
end

--------------------------------------------------------------------------------
-- Guarded RemoteFunction invoke (an unbound server can never hang the client)
--------------------------------------------------------------------------------

local function invokeShelf(remoteName: string, ...: any): { ok: boolean, err: string? }
	local args = table.pack(...)
	local done = false
	local result: any = nil
	task.spawn(function()
		local ok, reply = pcall(function()
			local remote = Remotes.GetFunction(remoteName)
			return remote:InvokeServer(table.unpack(args, 1, args.n))
		end)
		result = if ok then reply else nil
		done = true
	end)
	local deadline = os.clock() + INVOKE_TIMEOUT_SECONDS
	while not done and os.clock() < deadline do
		task.wait()
	end
	if not done or type(result) ~= "table" then
		return { ok = false, err = "TIMEOUT" }
	end
	return { ok = result.ok == true, err = if type(result.err) == "string" then result.err else nil }
end

--------------------------------------------------------------------------------
-- GUI primitives
--------------------------------------------------------------------------------

local function applyCorner(instance: Instance, radius: number)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius)
	corner.Parent = instance
end

local function applyStroke(instance: Instance, color: Color3, thickness: number): UIStroke
	local stroke = Instance.new("UIStroke")
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Color = color
	stroke.Thickness = thickness
	stroke.Parent = instance
	return stroke
end

local function makeLabel(parent: Instance, name: string, text: string): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = name
	label.BackgroundTransparency = 1
	label.Font = FONT
	label.Text = text
	label.TextColor3 = COLOR_TEXT
	label.TextSize = 16
	label.Parent = parent
	return label
end

local function makeButton(parent: Instance, name: string, text: string, color: Color3): TextButton
	local button = Instance.new("TextButton")
	button.Name = name
	button.AutoButtonColor = true
	button.BackgroundColor3 = color
	button.Font = FONT_BOLD
	button.Text = text
	button.TextColor3 = COLOR_TEXT
	button.TextSize = 18
	button.Size = UDim2.new(1, 0, 0, BUTTON_HEIGHT_PX)
	button.Parent = parent
	applyCorner(button, 10)
	return button
end

--------------------------------------------------------------------------------
-- Recipe -> greybox viewport thumbnail (render spec of record, CONTRACTS §E)
--------------------------------------------------------------------------------

local function makeGreyboxPart(shape: string, size: Vector3, cframe: CFrame, color: Color3): BasePart
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
	return part
end

-- Fills a ViewportFrame with the cryptling's recipe and frames a camera on it.
local function buildThumbnail(viewport: ViewportFrame, cryptlingId: string)
	local def = RarityTable.GetCryptling(cryptlingId)
	local baseColor = if type(def) == "table" and typeof(def.color) == "Color3"
		then def.color :: Color3
		else COLOR_RARITY_FALLBACK

	local maxY = 1.5
	local maxRadius = 1.2
	if type(def) == "table" and type(def.recipe) == "table" then
		for _, rp in def.recipe :: { any } do
			if typeof(rp.size) ~= "Vector3" or typeof(rp.offset) ~= "CFrame" then
				continue
			end
			local size = rp.size :: Vector3
			local offset = rp.offset :: CFrame
			local color = if typeof(rp.colorOverride) == "Color3" then rp.colorOverride :: Color3 else baseColor
			local part = makeGreyboxPart(rp.shape, size, offset, color)
			part.Parent = viewport
			maxY = math.max(maxY, offset.Position.Y + size.Y / 2)
			local horizontal = math.max(size.X, size.Z) / 2
			maxRadius =
				math.max(maxRadius, math.abs(offset.Position.X) + horizontal, math.abs(offset.Position.Z) + horizontal)
		end
	else
		-- Unknown id: a lone greybox ball still gives the card a body.
		makeGreyboxPart("Ball", Vector3.new(2, 2, 2), CFrame.new(0, 1, 0), baseColor).Parent = viewport
	end

	local focus = Vector3.new(0, maxY / 2, 0)
	local distance = math.max(maxRadius, maxY / 2) * 2.7 + 1.4
	local camera = Instance.new("Camera")
	camera.FieldOfView = 40
	camera.CFrame = CFrame.lookAt(focus + Vector3.new(distance * 0.45, maxY * 0.35 + 0.6, distance), focus)
	camera.Parent = viewport
	viewport.CurrentCamera = camera
end

local function makeViewport(parent: Instance, cryptlingId: string, heightPx: number): ViewportFrame
	local viewport = Instance.new("ViewportFrame")
	viewport.Name = "Thumb"
	viewport.BackgroundColor3 = COLOR_PANEL_DIM
	viewport.BackgroundTransparency = 0.25
	viewport.Size = UDim2.new(1, -12, 0, heightPx)
	viewport.Position = UDim2.fromOffset(6, 6)
	viewport.Ambient = Color3.fromRGB(140, 140, 140)
	viewport.LightColor = Color3.fromRGB(255, 250, 240)
	viewport.LightDirection = Vector3.new(-0.4, -1, -0.6)
	viewport.Parent = parent
	applyCorner(viewport, 8)
	buildThumbnail(viewport, cryptlingId)
	return viewport
end

--------------------------------------------------------------------------------
-- Toast (non-blocking error/info feedback)
--------------------------------------------------------------------------------

local ensureGui: () -> () -- forward-declared

local function toast(text: string)
	ensureGui()
	local label = toastLabel
	if label == nil then
		return
	end
	toastToken += 1
	local token = toastToken
	label.Text = text
	label.Visible = true
	label.TextTransparency = 0
	label.BackgroundTransparency = 0.15
	task.delay(TOAST_SECONDS, function()
		if toastToken == token and label.Parent ~= nil then
			TweenService:Create(label, TweenInfo.new(0.3), {
				TextTransparency = 1,
				BackgroundTransparency = 1,
			}):Play()
			task.delay(0.32, function()
				if toastToken == token then
					label.Visible = false
				end
			end)
		end
	end)
end

--------------------------------------------------------------------------------
-- Display hotspots (BillboardGui tap targets on every shelved Cryptling)
--------------------------------------------------------------------------------

local function dropHotspot(instance: Instance)
	local entry = hotspots[instance]
	if entry == nil then
		return
	end
	hotspots[instance] = nil
	for _, conn in entry.conns do
		conn:Disconnect()
	end
	entry.gui:Destroy()
end

local function restyleHotspot(instance: Instance, entry: HotspotEntry)
	local rawOwner = instance:GetAttribute(ATTR_OWNER_USER_ID)
	local isMine = type(rawOwner) == "number" and rawOwner == LocalPlayer.UserId
	entry.button.Text = if isMine then "EDIT" else "INSPECT"
	local cryptlingId = instance:GetAttribute(ATTR_CRYPTLING_ID)
	local def = if type(cryptlingId) == "string" then RarityTable.GetCryptling(cryptlingId) else nil
	entry.stroke.Color = rarityColor(if type(def) == "table" then def.rarity else nil)
end

local function onHotspotTapped(instance: Instance)
	local rawOwner = instance:GetAttribute(ATTR_OWNER_USER_ID)
	local rawCryptling = instance:GetAttribute(ATTR_CRYPTLING_ID)
	if type(rawOwner) ~= "number" or type(rawCryptling) ~= "string" then
		return
	end
	if rawOwner == LocalPlayer.UserId then
		-- Own room: same hotspot routes into edit mode (Swap / Remove).
		local rawSlot = instance:GetAttribute(ATTR_SLOT_ID)
		if type(rawSlot) == "string" then
			ShelfUI.OpenSlotSheet(rawSlot)
		end
	else
		ShelfUI.OpenVisitorCard(rawOwner, rawCryptling)
	end
end

local function watchDisplay(instance: Instance)
	if hotspots[instance] ~= nil then
		return
	end
	local adornee: BasePart? = nil
	if instance:IsA("BasePart") then
		adornee = instance
	elseif instance:IsA("Model") then
		adornee = instance.PrimaryPart or instance:FindFirstChildWhichIsA("BasePart")
	end
	if adornee == nil or worldGuiFolder == nil then
		return
	end

	local gui = Instance.new("BillboardGui")
	gui.Name = "ShelfDisplayHotspot"
	gui.Adornee = adornee
	gui.Size = UDim2.fromOffset(96, MIN_TOUCH_PX) -- >= 44px tap target (§G)
	gui.StudsOffset = Vector3.new(0, 2.6, 0)
	gui.MaxDistance = HOTSPOT_MAX_DISTANCE
	gui.LightInfluence = 0
	gui.Active = true
	gui.ResetOnSpawn = false

	local button = Instance.new("TextButton")
	button.Name = "Tap"
	button.AutoButtonColor = true
	button.BackgroundColor3 = COLOR_SHEET
	button.BackgroundTransparency = 0.25
	button.Font = FONT_BOLD
	button.TextColor3 = COLOR_TEXT
	button.TextSize = 15
	button.Size = UDim2.fromScale(1, 1)
	button.Parent = gui
	applyCorner(button, MIN_TOUCH_PX // 2)
	local stroke = applyStroke(button, COLOR_RARITY_FALLBACK, 2)

	gui.Parent = worldGuiFolder

	local entry: HotspotEntry = { gui = gui, button = button, stroke = stroke, conns = {} }
	hotspots[instance] = entry

	table.insert(
		entry.conns,
		button.Activated:Connect(function()
			onHotspotTapped(instance)
		end)
	)
	for _, attr in { ATTR_OWNER_USER_ID, ATTR_CRYPTLING_ID } do
		table.insert(
			entry.conns,
			instance:GetAttributeChangedSignal(attr):Connect(function()
				restyleHotspot(instance, entry)
			end)
		)
	end
	table.insert(
		entry.conns,
		instance.AncestryChanged:Connect(function(_, parent)
			if parent == nil then
				dropHotspot(instance)
			end
		end)
	)
	restyleHotspot(instance, entry)
end

--------------------------------------------------------------------------------
-- Slot-pad prompts (owner edit mode only — visitors get NO pad affordance)
--------------------------------------------------------------------------------

local function dropPad(instance: Instance)
	local entry = pads[instance]
	if entry == nil then
		return
	end
	pads[instance] = nil
	for _, conn in entry.conns do
		conn:Disconnect()
	end
	if entry.prompt ~= nil then
		entry.prompt:Destroy()
	end
end

local function refreshPadPrompt(instance: Instance, entry: PadEntry)
	local rawOwner = instance:GetAttribute(ATTR_OWNER_USER_ID)
	local isMine = type(rawOwner) == "number" and rawOwner == LocalPlayer.UserId
	if not isMine then
		if entry.prompt ~= nil then
			entry.prompt:Destroy()
			entry.prompt = nil
		end
		return
	end
	if entry.prompt ~= nil and entry.prompt.Parent == instance then
		return
	end
	-- Client-created prompt: replicates to no one else, so visitors in this
	-- room never see an edit affordance.
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "ShelfSlotPrompt"
	prompt.ActionText = "Edit Shelf Slot"
	prompt.ObjectText = "Display Shelf"
	prompt.HoldDuration = 0 -- single tap on touch
	prompt.MaxActivationDistance = PROMPT_DISTANCE
	prompt.RequiresLineOfSight = false
	prompt.Parent = instance
	prompt.Triggered:Connect(function()
		local rawSlot = instance:GetAttribute(ATTR_SLOT_ID)
		if type(rawSlot) == "string" then
			ShelfUI.OpenSlotSheet(rawSlot, instance:GetAttribute(ATTR_SLOT_LABEL))
		end
	end)
	entry.prompt = prompt
end

local function watchPad(instance: Instance)
	if pads[instance] ~= nil or not instance:IsA("BasePart") then
		return
	end
	local entry: PadEntry = { prompt = nil, conns = {} }
	pads[instance] = entry
	table.insert(
		entry.conns,
		instance:GetAttributeChangedSignal(ATTR_OWNER_USER_ID):Connect(function()
			refreshPadPrompt(instance, entry)
		end)
	)
	table.insert(
		entry.conns,
		instance.AncestryChanged:Connect(function(_, parent)
			if parent == nil then
				dropPad(instance)
			end
		end)
	)
	refreshPadPrompt(instance, entry)
end

--------------------------------------------------------------------------------
-- Bottom sheet shell
--------------------------------------------------------------------------------

local function sheetHeightPx(): number
	local camera = workspace.CurrentCamera
	local viewportY = if camera ~= nil then camera.ViewportSize.Y else 800
	return math.max(SHEET_MIN_HEIGHT_PX, math.floor(viewportY * SHEET_HEIGHT_SCALE))
end

ensureGui = function()
	if screenGui ~= nil and screenGui.Parent ~= nil then
		return
	end
	local playerGui = LocalPlayer:WaitForChild("PlayerGui")

	local gui = Instance.new("ScreenGui")
	gui.Name = "ShelfUI"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 46
	gui.IgnoreGuiInset = true
	gui.Enabled = true

	local dim = Instance.new("TextButton")
	dim.Name = "Backdrop"
	dim.AutoButtonColor = false
	dim.Text = ""
	dim.BackgroundColor3 = COLOR_BACKDROP
	dim.BackgroundTransparency = 0.45
	dim.Size = UDim2.fromScale(1, 1)
	dim.Visible = false
	dim.Parent = gui
	dim.Activated:Connect(function()
		ShelfUI.Close()
	end)

	local sheet = Instance.new("Frame")
	sheet.Name = "Sheet"
	sheet.AnchorPoint = Vector2.new(0.5, 1)
	sheet.BackgroundColor3 = COLOR_SHEET
	sheet.BorderSizePixel = 0
	sheet.Visible = false
	sheet.Parent = gui
	applyCorner(sheet, 16)

	local grabber = Instance.new("Frame")
	grabber.Name = "Grabber"
	grabber.BackgroundColor3 = COLOR_TEXT_DIM
	grabber.BorderSizePixel = 0
	grabber.AnchorPoint = Vector2.new(0.5, 0)
	grabber.Position = UDim2.new(0.5, 0, 0, 8)
	grabber.Size = UDim2.fromOffset(44, 4)
	grabber.Parent = sheet
	applyCorner(grabber, 2)

	local title = makeLabel(sheet, "Title", "")
	title.Font = FONT_BOLD
	title.TextSize = 20
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextTruncate = Enum.TextTruncate.AtEnd
	title.Position = UDim2.fromOffset(16, 18)
	title.Size = UDim2.new(1, -32 - CLOSE_PX, 0, CLOSE_PX)

	local close = Instance.new("TextButton")
	close.Name = "Close"
	close.AutoButtonColor = true
	close.BackgroundColor3 = COLOR_PANEL
	close.Font = FONT_BOLD
	close.Text = "X"
	close.TextColor3 = COLOR_TEXT
	close.TextSize = 20
	close.AnchorPoint = Vector2.new(1, 0)
	close.Position = UDim2.new(1, -12, 0, 18)
	close.Size = UDim2.fromOffset(CLOSE_PX, CLOSE_PX)
	close.Parent = sheet
	applyCorner(close, 10)
	close.Activated:Connect(function()
		ShelfUI.Close()
	end)

	local content = Instance.new("Frame")
	content.Name = "Content"
	content.BackgroundTransparency = 1
	content.Position = UDim2.fromOffset(12, 18 + CLOSE_PX + 8)
	content.Size = UDim2.new(1, -24, 1, -(18 + CLOSE_PX + 8) - 12)
	content.Parent = sheet

	local toastInstance = Instance.new("TextLabel")
	toastInstance.Name = "Toast"
	toastInstance.AnchorPoint = Vector2.new(0.5, 1)
	toastInstance.Position = UDim2.new(0.5, 0, 1, -120)
	toastInstance.Size = UDim2.fromOffset(320, MIN_TOUCH_PX)
	toastInstance.BackgroundColor3 = COLOR_PANEL
	toastInstance.BackgroundTransparency = 0.15
	toastInstance.Font = FONT_BOLD
	toastInstance.Text = ""
	toastInstance.TextColor3 = COLOR_TEXT
	toastInstance.TextSize = 16
	toastInstance.TextWrapped = true
	toastInstance.Visible = false
	toastInstance.ZIndex = 10
	toastInstance.Parent = gui
	applyCorner(toastInstance, 10)

	gui.Parent = playerGui

	screenGui = gui
	backdrop = dim
	sheetFrame = sheet
	sheetTitle = title
	sheetContent = content
	toastLabel = toastInstance
end

local function layoutSheet()
	local sheet = sheetFrame
	if sheet == nil then
		return
	end
	local camera = workspace.CurrentCamera
	local viewportX = if camera ~= nil then camera.ViewportSize.X else 600
	local width = math.min(SHEET_MAX_WIDTH_PX, viewportX) -- portrait-safe: full width on phones
	sheet.Size = UDim2.fromOffset(width, sheetHeightPx())
	sheet.Position = UDim2.fromScale(0.5, 1)
end

local function openSheetShell()
	ensureGui()
	layoutSheet()
	local dim = backdrop
	local sheet = sheetFrame
	if dim == nil or sheet == nil then
		return
	end
	dim.Visible = true
	sheet.Visible = true
	if not sheetOpen then
		sheetOpen = true
		local height = sheetHeightPx()
		sheet.Position = UDim2.new(0.5, 0, 1, height)
		TweenService
			:Create(sheet, TweenInfo.new(SHEET_SLIDE_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				Position = UDim2.fromScale(0.5, 1),
			})
			:Play()
	end
end

local function clearContent()
	local content = sheetContent
	if content == nil then
		return
	end
	for _, child in content:GetChildren() do
		child:Destroy()
	end
end

--------------------------------------------------------------------------------
-- Actions (optimistic + reconciled)
--------------------------------------------------------------------------------

local function markOptimistic(slotId: string, intent: string | false)
	optimistic[slotId] = intent
	optimisticStamp[slotId] = os.clock()
end

local function clearOptimistic(slotId: string)
	optimistic[slotId] = nil
	optimisticStamp[slotId] = nil
end

local function placeCryptling(slotId: string, cryptlingId: string)
	markOptimistic(slotId, cryptlingId)
	ShelfUI.Close() -- result is visible in the room itself via ShelfChanged
	task.spawn(function()
		local reply = invokeShelf("Shelf.Place", slotId, cryptlingId)
		if not reply.ok then
			if optimistic[slotId] == cryptlingId then
				clearOptimistic(slotId)
				if currentSheet ~= nil then
					renderSheet()
				end
			end
			toast(`Couldn't display {cryptlingDisplayName(cryptlingId)} — {errCopy(reply.err)}`)
		end
	end)
end

local function removeFromSlot(slotId: string)
	markOptimistic(slotId, false)
	ShelfUI.Close()
	task.spawn(function()
		local reply = invokeShelf("Shelf.Remove", slotId)
		if not reply.ok then
			if optimistic[slotId] == false then
				clearOptimistic(slotId)
				if currentSheet ~= nil then
					renderSheet()
				end
			end
			toast(`Couldn't clear that slot — {errCopy(reply.err)}`)
		end
	end)
end

--------------------------------------------------------------------------------
-- Sheet content: owner picker
--------------------------------------------------------------------------------

type PickerRow = { id: string, owned: number, displayed: number, def: any }

local function sortedOwnedRows(): { PickerRow }
	local counts = myCollection() or {}
	local rows: { PickerRow } = {}
	for id, owned in counts do
		local def = RarityTable.GetCryptling(id)
		table.insert(rows, { id = id, owned = owned, displayed = displayedCount(id), def = def })
	end
	table.sort(rows, function(a, b)
		local rarityA = if type(a.def) == "table" then RARITY_RANK[a.def.rarity] or 0 else 0
		local rarityB = if type(b.def) == "table" then RARITY_RANK[b.def.rarity] or 0 else 0
		if rarityA ~= rarityB then
			return rarityA > rarityB -- Godly first: lead with the flex
		end
		local orderA = ROSTER_ORDER[a.id] or math.huge
		local orderB = ROSTER_ORDER[b.id] or math.huge
		if orderA ~= orderB then
			return orderA < orderB
		end
		return a.id < b.id
	end)
	return rows
end

local function buildPickerCard(parent: Instance, row: PickerRow, slotId: string, currentId: string?)
	local rarity: string? = if type(row.def) == "table" then row.def.rarity else nil
	local frameColor = rarityColor(rarity)
	-- Fully displayed = every owned copy is already on a slot. Swapping the
	-- same id onto the slot it occupies is also a no-op, so it dims too.
	local fullyDisplayed = row.displayed >= row.owned or row.id == currentId

	local card = Instance.new("TextButton")
	card.Name = row.id
	card.AutoButtonColor = not fullyDisplayed
	card.Active = not fullyDisplayed
	card.Text = ""
	card.BackgroundColor3 = COLOR_PANEL
	card.Size = UDim2.fromOffset(CARD_WIDTH_PX, CARD_HEIGHT_PX)
	card.Parent = parent
	applyCorner(card, 10)
	applyStroke(card, frameColor, 2) -- rarity color frame (§E colors everywhere)

	makeViewport(card, row.id, 78)

	local nameLabel = makeLabel(card, "CryptlingName", cryptlingDisplayName(row.id))
	nameLabel.TextSize = 14
	nameLabel.TextTruncate = Enum.TextTruncate.AtEnd
	nameLabel.Position = UDim2.fromOffset(6, 88)
	nameLabel.Size = UDim2.new(1, -12, 0, 18)

	local rarityLabel = makeLabel(card, "Rarity", rarity or "???")
	rarityLabel.TextColor3 = frameColor
	rarityLabel.TextSize = 13
	rarityLabel.Position = UDim2.fromOffset(6, 106)
	rarityLabel.Size = UDim2.new(1, -12, 0, 16)

	-- Owned-count badge (top right).
	local countBadge = makeLabel(card, "OwnedCount", `x{row.owned}`)
	countBadge.BackgroundTransparency = 0.1
	countBadge.BackgroundColor3 = COLOR_SHEET
	countBadge.Font = FONT_BOLD
	countBadge.TextSize = 13
	countBadge.AnchorPoint = Vector2.new(1, 0)
	countBadge.Position = UDim2.new(1, -4, 0, 4)
	countBadge.Size = UDim2.fromOffset(32, 20)
	countBadge.ZIndex = 3
	applyCorner(countBadge, 6)

	-- DUPE tag (top left) when count > 1 — the trading nudge (SOP §1.2).
	if row.owned > 1 then
		local dupe = makeLabel(card, "DupeTag", "DUPE")
		dupe.BackgroundTransparency = 0
		dupe.BackgroundColor3 = COLOR_GOLD
		dupe.TextColor3 = Color3.fromRGB(40, 32, 8)
		dupe.Font = FONT_BOLD
		dupe.TextSize = 12
		dupe.Position = UDim2.fromOffset(4, 4)
		dupe.Size = UDim2.fromOffset(44, 20)
		dupe.ZIndex = 3
		applyCorner(dupe, 6)
	end

	if fullyDisplayed then
		local dimOverlay = Instance.new("Frame")
		dimOverlay.Name = "DimOverlay"
		dimOverlay.BackgroundColor3 = COLOR_SHEET
		dimOverlay.BackgroundTransparency = 0.45
		dimOverlay.BorderSizePixel = 0
		dimOverlay.Size = UDim2.fromScale(1, 1)
		dimOverlay.ZIndex = 4
		dimOverlay.Parent = card
		applyCorner(dimOverlay, 10)

		local displayedTag = makeLabel(dimOverlay, "DisplayedTag", "DISPLAYED")
		displayedTag.Font = FONT_BOLD
		displayedTag.TextSize = 13
		displayedTag.TextColor3 = COLOR_TEXT_DIM
		displayedTag.AnchorPoint = Vector2.new(0.5, 0.5)
		displayedTag.Position = UDim2.fromScale(0.5, 0.5)
		displayedTag.Size = UDim2.new(1, 0, 0, 18)
		displayedTag.ZIndex = 5
	else
		card.Activated:Connect(function()
			placeCryptling(slotId, row.id)
		end)
	end
end

local function renderPicker(request: SheetRequest)
	local content = sheetContent
	local title = sheetTitle
	local slotId = request.slotId
	if content == nil or title == nil or slotId == nil then
		return
	end
	title.Text = `Display a Cryptling — {request.slotLabel or slotId}`

	local rows = sortedOwnedRows()
	if #rows == 0 then
		local empty = makeLabel(content, "Empty", GameConstants.EMPTY_STATE.PODIUM_EMPTY)
		empty.TextColor3 = COLOR_TEXT_DIM
		empty.TextWrapped = true
		empty.Size = UDim2.fromScale(1, 1)
		return
	end

	local scroll = Instance.new("ScrollingFrame")
	scroll.Name = "Grid"
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.Size = UDim2.fromScale(1, 1)
	scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.ScrollBarThickness = 6
	scroll.ScrollingDirection = Enum.ScrollingDirection.Y
	scroll.Parent = content

	local grid = Instance.new("UIGridLayout")
	grid.CellSize = UDim2.fromOffset(CARD_WIDTH_PX, CARD_HEIGHT_PX)
	grid.CellPadding = UDim2.fromOffset(GRID_GAP_PX, GRID_GAP_PX)
	grid.SortOrder = Enum.SortOrder.LayoutOrder
	grid.HorizontalAlignment = Enum.HorizontalAlignment.Center
	grid.Parent = scroll

	local currentId = effectiveOwnSlots()[slotId]
	for index, row in rows do
		local holder = Instance.new("Frame")
		holder.Name = `Cell{index}`
		holder.BackgroundTransparency = 1
		holder.LayoutOrder = index
		holder.Parent = scroll
		buildPickerCard(holder, row, slotId, currentId)
	end
end

--------------------------------------------------------------------------------
-- Sheet content: occupied slot (Swap / Remove)
--------------------------------------------------------------------------------

local function renderOccupied(request: SheetRequest)
	local content = sheetContent
	local title = sheetTitle
	local slotId = request.slotId
	local cryptlingId = request.cryptlingId
	if content == nil or title == nil or slotId == nil or cryptlingId == nil then
		return
	end
	title.Text = `Shelf Slot — {request.slotLabel or slotId}`

	local def = RarityTable.GetCryptling(cryptlingId)
	local rarity: string? = if type(def) == "table" then def.rarity else nil
	local color = rarityColor(rarity)

	local preview = Instance.new("Frame")
	preview.Name = "Preview"
	preview.BackgroundColor3 = COLOR_PANEL
	preview.Size = UDim2.new(1, 0, 1, -(BUTTON_HEIGHT_PX * 2 + 20))
	preview.Parent = content
	applyCorner(preview, 12)
	applyStroke(preview, color, 2)

	local viewport = makeViewport(preview, cryptlingId, 0)
	viewport.Size = UDim2.new(1, -12, 1, -64)

	local nameLabel = makeLabel(preview, "CryptlingName", cryptlingDisplayName(cryptlingId))
	nameLabel.Font = FONT_BOLD
	nameLabel.TextSize = 20
	nameLabel.AnchorPoint = Vector2.new(0, 1)
	nameLabel.Position = UDim2.new(0, 12, 1, -32)
	nameLabel.Size = UDim2.new(1, -24, 0, 24)
	nameLabel.TextXAlignment = Enum.TextXAlignment.Left

	local rarityLabel = makeLabel(preview, "Rarity", rarity or "???")
	rarityLabel.TextColor3 = color
	rarityLabel.TextSize = 15
	rarityLabel.AnchorPoint = Vector2.new(0, 1)
	rarityLabel.Position = UDim2.new(0, 12, 1, -8)
	rarityLabel.Size = UDim2.new(1, -24, 0, 20)
	rarityLabel.TextXAlignment = Enum.TextXAlignment.Left

	local swapButton = makeButton(content, "Swap", "SWAP", COLOR_PANEL)
	applyStroke(swapButton, COLOR_CONFIRM, 1.5)
	swapButton.AnchorPoint = Vector2.new(0, 1)
	swapButton.Position = UDim2.new(0, 0, 1, -(BUTTON_HEIGHT_PX + 10))
	swapButton.Activated:Connect(function()
		currentSheet = {
			mode = "picker",
			slotId = slotId,
			slotLabel = request.slotLabel,
		}
		renderSheet()
	end)

	local removeButton = makeButton(content, "Remove", "REMOVE", COLOR_PANEL)
	applyStroke(removeButton, COLOR_DANGER, 1.5)
	removeButton.TextColor3 = COLOR_DANGER
	removeButton.AnchorPoint = Vector2.new(0, 1)
	removeButton.Position = UDim2.fromScale(0, 1)
	removeButton.Activated:Connect(function()
		removeFromSlot(slotId)
	end)
end

--------------------------------------------------------------------------------
-- Sheet content: visitor card (READ-ONLY — never any edit affordance)
--------------------------------------------------------------------------------

local function renderVisitor(request: SheetRequest)
	local content = sheetContent
	local title = sheetTitle
	local cryptlingId = request.cryptlingId
	if content == nil or title == nil or cryptlingId == nil then
		return
	end
	local def = RarityTable.GetCryptling(cryptlingId)
	local rarity: string? = if type(def) == "table" then def.rarity else nil
	local color = rarityColor(rarity)

	title.Text = cryptlingDisplayName(cryptlingId)

	local card = Instance.new("Frame")
	card.Name = "VisitorCard"
	card.BackgroundColor3 = COLOR_PANEL
	card.Size = UDim2.fromScale(1, 1)
	card.Parent = content
	applyCorner(card, 12)
	applyStroke(card, color, 2)

	local viewport = makeViewport(card, cryptlingId, 0)
	viewport.Size = UDim2.new(1, -12, 1, -96)

	local rarityLabel = makeLabel(card, "Rarity", rarity or "???")
	rarityLabel.Font = FONT_BOLD
	rarityLabel.TextColor3 = color -- rarity name in rarity color (§E)
	rarityLabel.TextSize = 18
	rarityLabel.AnchorPoint = Vector2.new(0, 1)
	rarityLabel.Position = UDim2.new(0, 12, 1, -52)
	rarityLabel.Size = UDim2.new(1, -24, 0, 24)
	rarityLabel.TextXAlignment = Enum.TextXAlignment.Left

	-- The kept in-room pool read: "N of 12 — Factory Floor Misfits" (the only
	-- progress-style text ShelfUI still renders after Addendum 2 R3-6).
	local poolIndex = POOL_INDEX[cryptlingId]
	local lineText = if poolIndex ~= nil
		then `{poolIndex} of {POOL_SIZE} — {RarityTable.LINE_NAME}`
		else `Special Edition — {RarityTable.LINE_NAME}`
	local lineLabel = makeLabel(card, "LineInfo", lineText)
	lineLabel.TextColor3 = COLOR_TEXT_DIM
	lineLabel.TextSize = 15
	lineLabel.AnchorPoint = Vector2.new(0, 1)
	lineLabel.Position = UDim2.new(0, 12, 1, -24)
	lineLabel.Size = UDim2.new(1, -24, 0, 22)
	lineLabel.TextXAlignment = Enum.TextXAlignment.Left
end

--------------------------------------------------------------------------------
-- Sheet routing
--------------------------------------------------------------------------------

renderSheet = function()
	local request = currentSheet
	if request == nil then
		return
	end
	openSheetShell()
	clearContent()
	if request.mode == "picker" then
		renderPicker(request)
	elseif request.mode == "occupied" then
		renderOccupied(request)
	else
		renderVisitor(request)
	end
end

--------------------------------------------------------------------------------
-- Server events
--------------------------------------------------------------------------------

local function onShelfChanged(payload: any)
	if type(payload) ~= "table" or type(payload.ownerUserId) ~= "number" or type(payload.slots) ~= "table" then
		return
	end
	local ownerUserId = payload.ownerUserId :: number
	local sanitized: { [string]: string } = {}
	for slotId, cryptlingId in payload.slots :: { [any]: any } do
		if type(slotId) == "string" and type(cryptlingId) == "string" then
			sanitized[slotId] = cryptlingId
		end
	end
	serverShelves[ownerUserId] = sanitized

	if ownerUserId == LocalPlayer.UserId then
		-- Reconcile: drop every optimistic intent the server has now answered.
		for slotId, intent in optimistic do
			local serverValue = sanitized[slotId]
			local satisfied = if intent == false then serverValue == nil else serverValue == intent
			if satisfied then
				clearOptimistic(slotId)
			end
		end
		-- Re-render an open owner sheet against the authoritative state (the
		-- occupied sheet may now show a different occupant, the picker new dims).
		local request = currentSheet
		if request ~= nil and request.mode ~= "visitor" then
			if request.mode == "occupied" and request.slotId ~= nil then
				local occupant = effectiveOwnSlots()[request.slotId]
				if occupant == nil then
					currentSheet = { mode = "picker", slotId = request.slotId, slotLabel = request.slotLabel }
				else
					request.cryptlingId = occupant
				end
			end
			renderSheet()
		end
	end
end

local function onShiftState(payload: any)
	-- Shelf rooms are hub-side; never leave a sheet up once a run starts.
	if type(payload) == "table" and payload.state == "Active" then
		ShelfUI.Close()
	end
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- Owner entry point: routes by occupancy — empty slot -> picker, occupied
-- slot -> Swap / Remove. slotLabel is optional pretty copy for the title.
function ShelfUI.OpenSlotSheet(slotId: string, slotLabel: any)
	if type(slotId) ~= "string" or slotId == "" then
		return
	end
	local label: string? = if type(slotLabel) == "string" and slotLabel ~= "" then slotLabel else nil
	local occupant = effectiveOwnSlots()[slotId]
	if occupant ~= nil then
		currentSheet = { mode = "occupied", slotId = slotId, slotLabel = label, cryptlingId = occupant }
	else
		currentSheet = { mode = "picker", slotId = slotId, slotLabel = label }
	end
	setCursorReleased(true)
	renderSheet()
end

-- Visitor entry point: strictly read-only (acceptance: never any edit control).
function ShelfUI.OpenVisitorCard(ownerUserId: number, cryptlingId: string)
	if type(ownerUserId) ~= "number" or type(cryptlingId) ~= "string" then
		return
	end
	currentSheet = { mode = "visitor", ownerUserId = ownerUserId, cryptlingId = cryptlingId }
	setCursorReleased(true)
	renderSheet()
end

function ShelfUI.Close()
	-- Release before the early-out: drops the token even if the sheet never
	-- finished opening (release is idempotent, token set not a counter).
	setCursorReleased(false)
	currentSheet = nil
	if not sheetOpen then
		return
	end
	sheetOpen = false
	local dim = backdrop
	local sheet = sheetFrame
	if dim ~= nil then
		dim.Visible = false
	end
	if sheet ~= nil then
		local height = sheetHeightPx()
		local tween = TweenService:Create(
			sheet,
			TweenInfo.new(SHEET_SLIDE_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
			{ Position = UDim2.new(0.5, 0, 1, height) }
		)
		tween.Completed:Connect(function()
			if not sheetOpen and sheet ~= nil then
				sheet.Visible = false
			end
		end)
		tween:Play()
	end
end

function ShelfUI.IsOpen(): boolean
	return sheetOpen
end

-- Last known shelf for an owner (own shelf includes optimistic edits). Other
-- controllers / the room renderer may read this instead of caching ShelfChanged.
function ShelfUI.GetKnownShelf(ownerUserId: number): { [string]: string }?
	if ownerUserId == LocalPlayer.UserId then
		return effectiveOwnSlots()
	end
	local slots = serverShelves[ownerUserId]
	return if slots ~= nil then table.clone(slots) else nil
end

--------------------------------------------------------------------------------
-- Lifecycle (Stage 0 loader contract: Init no yields, Start spawned)
--------------------------------------------------------------------------------

function ShelfUI:Init(registry: any)
	registryRef = registry

	-- Tag watchers: connections only, no yields. Initial sweeps run in Start.
	CollectionService:GetInstanceAddedSignal(TAG_SLOT_PAD):Connect(function(instance: Instance)
		task.defer(watchPad, instance)
	end)
	CollectionService:GetInstanceRemovedSignal(TAG_SLOT_PAD):Connect(dropPad)

	CollectionService:GetInstanceAddedSignal(TAG_DISPLAY):Connect(function(instance: Instance)
		task.defer(watchDisplay, instance)
	end)
	CollectionService:GetInstanceRemovedSignal(TAG_DISPLAY):Connect(dropHotspot)

	-- Own collection changes re-dim the picker (e.g. a trade completes while
	-- it is open).
	LocalPlayer:GetAttributeChangedSignal(ATTR_COLLECTION):Connect(function()
		local request = currentSheet
		if request ~= nil and request.mode == "picker" then
			task.defer(renderSheet)
		end
	end)
end

function ShelfUI:Start()
	ensureGui()

	-- World-anchored guis live in PlayerGui so BillboardGui buttons receive taps.
	local playerGui = LocalPlayer:WaitForChild("PlayerGui")
	local folder = Instance.new("Folder")
	folder.Name = "ShelfWorldGui"
	folder.Parent = playerGui
	worldGuiFolder = folder

	-- Initial sweeps (rooms may already exist by the time this controller runs).
	for _, instance in CollectionService:GetTagged(TAG_SLOT_PAD) do
		watchPad(instance)
	end
	for _, instance in CollectionService:GetTagged(TAG_DISPLAY) do
		watchDisplay(instance)
	end

	Remotes.GetEvent("ShelfChanged").OnClientEvent:Connect(onShelfChanged)
	Remotes.GetEvent("ShiftState").OnClientEvent:Connect(onShiftState)

	-- Late-join sync (contract §B Shelf.GetAll): pull one ShelfChanged-shaped
	-- snapshot per loaded owner. Connected-then-pulled, and a live push that
	-- raced the reply wins (never clobber a newer broadcast with the pull).
	task.spawn(function()
		local ok, snapshots = pcall(function()
			return Remotes.GetFunction("Shelf.GetAll"):InvokeServer()
		end)
		if not ok or type(snapshots) ~= "table" then
			return
		end
		for _, snapshot in snapshots :: { any } do
			if
				type(snapshot) == "table"
				and type(snapshot.ownerUserId) == "number"
				and type(snapshot.slots) == "table"
				and serverShelves[snapshot.ownerUserId] == nil
			then
				onShelfChanged(snapshot)
			end
		end
	end)

	-- Keep the sheet inside the screen across rotation / viewport changes.
	local camera = workspace.CurrentCamera
	if camera ~= nil then
		camera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
			if sheetOpen then
				layoutSheet()
			end
		end)
	end
end

return ShelfUI
