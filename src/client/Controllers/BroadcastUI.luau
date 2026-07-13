--!strict
-- CRYPTLINGS: NIGHT SHIFT — BroadcastUI (Stage 2, module unboxing-theater-ui).
-- Server-wide RARE PULL banners (SOP §3.1 ②): the RarePullBroadcast remote
-- (same-server + cross-server via MessagingService, fanned out by the server)
-- queues a top banner — "[player] pulled [name]!" in the rarity color, shown
-- 6s each, strictly one at a time so banners never overlap. Godly pulls also
-- sweep a screen-wide gold shimmer.
--
-- NEVER blocks touch input: every element is a non-Active Frame/TextLabel
-- (input passes straight through), there are no buttons, and nothing covers
-- the screen with an Active surface.
--
-- Public API (Controllers.Get("BroadcastUI")):
--   Enqueue(payload {playerName, cryptlingId, rarity}) -- local enqueue, same
--       path the remote uses (handy for later stages / testing).
--
-- Mobile-first (§3.2/§G): viewport-driven UIScale, safe-area insets.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RarityTable = require(Shared:WaitForChild("Config"):WaitForChild("RarityTable"))
local Remotes = require(Shared:WaitForChild("Net"):WaitForChild("Remotes"))

local LocalPlayer = Players.LocalPlayer

--------------------------------------------------------------------------------
-- Tuning (cosmetic, this module's domain)
--------------------------------------------------------------------------------

local BANNER_SECONDS = 6 -- spec: each banner holds 6s
local SLIDE_SECONDS = 0.3
local QUEUE_MAX = 8 -- drop the oldest beyond this; a banner backlog must never run minutes behind
local SHIMMER_SECONDS = 1.8

local DESIGN_SHORT_AXIS_PX = 450
local UISCALE_MIN = 0.85
local UISCALE_MAX = 1.6

local BANNER_WIDTH_PX = 330
local BANNER_HEIGHT_PX = 56
local BANNER_TOP_PX = 72 -- clears RunHUD's shift timer (ends 50) and noise meter (ends 64)

local COLOR_PANEL = Color3.fromRGB(18, 20, 24)
local COLOR_TEXT_DIM = Color3.fromRGB(160, 166, 172)
local COLOR_GOLD = Color3.fromRGB(235, 190, 52)
local COLOR_FALLBACK = Color3.fromRGB(178, 178, 178)

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local BroadcastUI = {}

type Pull = { playerName: string, cryptlingId: string, rarity: string }
local queue: { Pull } = {}

local uiScale: UIScale? = nil
local banner: Frame? = nil
local captionLabel: TextLabel? = nil
local pullLabel: TextLabel? = nil
local bannerStroke: UIStroke? = nil
local shimmer: Frame? = nil
local shimmerGradient: UIGradient? = nil

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function rarityColor(rarity: string): Color3
	local color = (RarityTable.RARITY_COLORS :: any)[rarity]
	if typeof(color) == "Color3" then
		return color
	end
	return COLOR_FALLBACK
end

local function cryptlingDisplayName(cryptlingId: string): string
	local def = RarityTable.GetCryptling(cryptlingId)
	if type(def) == "table" and type(def.name) == "string" then
		return def.name
	end
	return cryptlingId
end

--------------------------------------------------------------------------------
-- GUI construction
--------------------------------------------------------------------------------

local function updateScale()
	local camera = workspace.CurrentCamera
	if camera == nil or uiScale == nil then
		return
	end
	local shortAxis = math.min(camera.ViewportSize.X, camera.ViewportSize.Y)
	if shortAxis > 0 then
		uiScale.Scale = math.clamp(shortAxis / DESIGN_SHORT_AXIS_PX, UISCALE_MIN, UISCALE_MAX)
	end
end

local function buildGui(): ScreenGui
	local gui = Instance.new("ScreenGui")
	gui.Name = "BroadcastUI"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = false
	gui.ScreenInsets = Enum.ScreenInsets.DeviceSafeInsets
	gui.DisplayOrder = 40 -- above theater (20) and odds (24): broadcasts top everything

	-- Gold shimmer (godly only): a full-screen NON-Active frame whose gradient
	-- band sweeps across. Input passes through untouched.
	local shimmerFrame = Instance.new("Frame")
	shimmerFrame.Name = "GoldShimmer"
	shimmerFrame.Size = UDim2.fromScale(1, 1)
	shimmerFrame.BackgroundColor3 = COLOR_GOLD
	shimmerFrame.BackgroundTransparency = 1
	shimmerFrame.BorderSizePixel = 0
	shimmerFrame.ZIndex = 1
	local gradient = Instance.new("UIGradient")
	gradient.Rotation = 18
	gradient.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.42, 1),
		NumberSequenceKeypoint.new(0.5, 0.45),
		NumberSequenceKeypoint.new(0.58, 1),
		NumberSequenceKeypoint.new(1, 1),
	})
	gradient.Offset = Vector2.new(-1, 0)
	gradient.Parent = shimmerFrame
	shimmerFrame.Parent = gui
	shimmer = shimmerFrame
	shimmerGradient = gradient

	local root = Instance.new("Frame")
	root.Name = "Root"
	root.Size = UDim2.fromScale(1, 1)
	root.BackgroundTransparency = 1
	root.ZIndex = 2
	root.Parent = gui

	local scale = Instance.new("UIScale")
	scale.Parent = root
	uiScale = scale

	local bannerFrame = Instance.new("Frame")
	bannerFrame.Name = "Banner"
	bannerFrame.AnchorPoint = Vector2.new(0.5, 0)
	bannerFrame.Position = UDim2.new(0.5, 0, 0, -(BANNER_HEIGHT_PX + 12)) -- parked off-screen
	bannerFrame.Size = UDim2.fromOffset(BANNER_WIDTH_PX, BANNER_HEIGHT_PX)
	bannerFrame.BackgroundColor3 = COLOR_PANEL
	bannerFrame.BackgroundTransparency = 0.12
	bannerFrame.BorderSizePixel = 0
	bannerFrame.Visible = false
	bannerFrame.ZIndex = 3
	bannerFrame.Parent = root
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 12)
	corner.Parent = bannerFrame
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.Color = COLOR_FALLBACK
	stroke.Parent = bannerFrame
	bannerStroke = stroke

	local caption = Instance.new("TextLabel")
	caption.Name = "Caption"
	caption.BackgroundTransparency = 1
	caption.Position = UDim2.fromOffset(0, 6)
	caption.Size = UDim2.new(1, 0, 0, 14)
	caption.Font = Enum.Font.GothamBold
	caption.TextSize = 11
	caption.TextColor3 = COLOR_TEXT_DIM
	caption.Text = "RARE PULL"
	caption.ZIndex = 4
	caption.Parent = bannerFrame
	captionLabel = caption

	local pull = Instance.new("TextLabel")
	pull.Name = "Pull"
	pull.BackgroundTransparency = 1
	pull.Position = UDim2.fromOffset(8, 22)
	pull.Size = UDim2.new(1, -16, 0, 26)
	pull.Font = Enum.Font.GothamBold
	pull.TextSize = 17
	pull.TextScaled = false
	pull.TextTruncate = Enum.TextTruncate.AtEnd
	pull.TextColor3 = COLOR_FALLBACK
	pull.TextStrokeTransparency = 0.7
	pull.Text = ""
	pull.ZIndex = 4
	pull.Parent = bannerFrame
	pullLabel = pull
	banner = bannerFrame

	return gui
end

--------------------------------------------------------------------------------
-- Presentation
--------------------------------------------------------------------------------

local function playShimmer()
	local frame = shimmer
	local gradient = shimmerGradient
	if frame == nil or gradient == nil then
		return
	end
	gradient.Offset = Vector2.new(-1, 0)
	frame.BackgroundTransparency = 0.25
	TweenService:Create(
		gradient,
		TweenInfo.new(SHIMMER_SECONDS, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
		{ Offset = Vector2.new(1, 0) }
	):Play()
	task.delay(SHIMMER_SECONDS, function()
		if frame ~= nil then
			frame.BackgroundTransparency = 1
		end
	end)
end

-- Shows one banner start-to-finish (yields ~SLIDE + 6s + SLIDE). The worker
-- loop serializes calls, so banners queue without overlap by construction.
local function showBanner(pull: Pull)
	local frame = banner
	local label = pullLabel
	local caption = captionLabel
	local stroke = bannerStroke
	if frame == nil then
		return
	end

	local color = rarityColor(pull.rarity)
	if label ~= nil then
		label.Text = `{pull.playerName} pulled {cryptlingDisplayName(pull.cryptlingId)}!`
		label.TextColor3 = color
	end
	if caption ~= nil then
		-- Tier display copy of record (RARITY_DISPLAY) — string.upper only
		-- touches ASCII, so Mythical's 『』 marks survive intact.
		local display = (RarityTable.RARITY_DISPLAY :: any)[pull.rarity] or pull.rarity
		caption.Text = string.upper(`{display} PULL`)
	end
	if stroke ~= nil then
		stroke.Color = color
	end

	if pull.rarity == "Legendary" or pull.rarity == "Godly" or pull.rarity == "Mythical" then
		playShimmer() -- the shimmer covers every top tier now
	end

	frame.Position = UDim2.new(0.5, 0, 0, -(BANNER_HEIGHT_PX + 12))
	frame.Visible = true
	local slideIn = TweenService:Create(
		frame,
		TweenInfo.new(SLIDE_SECONDS, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
		{ Position = UDim2.new(0.5, 0, 0, BANNER_TOP_PX) }
	)
	slideIn:Play()
	slideIn.Completed:Wait()

	task.wait(BANNER_SECONDS)

	local slideOut = TweenService:Create(
		frame,
		TweenInfo.new(SLIDE_SECONDS, Enum.EasingStyle.Quint, Enum.EasingDirection.In),
		{ Position = UDim2.new(0.5, 0, 0, -(BANNER_HEIGHT_PX + 12)) }
	)
	slideOut:Play()
	slideOut.Completed:Wait()
	frame.Visible = false
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

function BroadcastUI.Enqueue(payload: any)
	if
		type(payload) ~= "table"
		or type(payload.playerName) ~= "string"
		or type(payload.cryptlingId) ~= "string"
		or type(payload.rarity) ~= "string"
	then
		return
	end
	if #queue >= QUEUE_MAX then
		table.remove(queue, 1)
	end
	table.insert(queue, {
		playerName = payload.playerName,
		cryptlingId = payload.cryptlingId,
		rarity = payload.rarity,
	})
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function BroadcastUI:Start()
	local gui = buildGui()
	gui.Parent = LocalPlayer:WaitForChild("PlayerGui")

	updateScale()
	local camera = workspace.CurrentCamera
	if camera ~= nil then
		camera:GetPropertyChangedSignal("ViewportSize"):Connect(updateScale)
	end

	Remotes.GetEvent("RarePullBroadcast").OnClientEvent:Connect(BroadcastUI.Enqueue)

	-- Serial worker: one banner at a time, in arrival order.
	while true do
		local pull = table.remove(queue, 1)
		if pull ~= nil then
			showBanner(pull)
		else
			task.wait(0.1)
		end
	end
end

return BroadcastUI
