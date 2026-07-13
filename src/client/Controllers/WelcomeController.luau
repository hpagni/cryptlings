--!strict
-- CRYPTLINGS: NIGHT SHIFT — WelcomeController (R7 Fix #1, Lane B).
-- The first-ever WELCOME panel for brand-new players (AUDIENCE = KIDS). On the
-- ShowWelcome remote (server fires it at most once per account, AFTER granting
-- the guaranteed-rare starter case into the locker), this builds ONE centered
-- modal: a friendly "here's what to do" card with the kid-simple copy of record
-- (GameConstants.WELCOME). Tapping GOT IT destroys the panel and hands off to
-- the StarterGuideController step machine.
--
--   * One ScreenGui modal, ZIndexBehavior.Sibling, IgnoreGuiInset, DisplayOrder
--     above the HUD/chips, viewport-driven UIScale (~450px short-axis clamp).
--   * Semi-transparent dark backdrop so the panel reads, but NO input lock —
--     the backdrop is purely visual; the player can still see the world behind.
--   * Every line short, simple, one idea at a time; the FACTORY word accented.
--   * One-shot: shows once per ShowWelcome fire, destroys on dismiss; a missing
--     StarterGuideController degrades to a no-op (the panel still works).
--
-- This is SEPARATE from OnboardingController (the in-shift OnboardingBeat). The
-- two coexist; this controller never touches that flow.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConstants = require(Shared:WaitForChild("Config"):WaitForChild("GameConstants"))
local Remotes = require(Shared:WaitForChild("Net"):WaitForChild("Remotes"))

local LocalPlayer = Players.LocalPlayer

--------------------------------------------------------------------------------
-- Tuning (cosmetic, this module's domain)
--------------------------------------------------------------------------------

local MIN_TOUCH_PX = GameConstants.MOBILE_MIN_TOUCH_TARGET_PX -- 44
local DISMISS_HEIGHT_PX = math.max(MIN_TOUCH_PX, 52)

-- Design-space scaling, same recipe as OnboardingController/RunHUD: authored
-- against a ~450px short axis, clamped so desktop never balloons.
local DESIGN_SHORT_AXIS_PX = 450
local UISCALE_MIN = 0.85
local UISCALE_MAX = 1.6

local DISPLAY_ORDER = 60 -- above the HUD chips (locker 15, pets 14) and toasts
local PANEL_WIDTH_PX = 360
local FADE_SECONDS = 0.2

local COLOR_BACKDROP = Color3.fromRGB(8, 9, 12)
local COLOR_PANEL = Color3.fromRGB(24, 27, 33)
local COLOR_TEXT = Color3.fromRGB(235, 238, 240)
local COLOR_TITLE = Color3.fromRGB(255, 224, 130) -- friendly warm welcome gold
local COLOR_FACTORY = Color3.fromRGB(120, 230, 140) -- accent for the FACTORY line
local COLOR_DISMISS = Color3.fromRGB(80, 200, 120) -- big green GOT IT button
local COLOR_DISMISS_TEXT = Color3.fromRGB(12, 14, 16)

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local WelcomeController = {}

local registryRef: any = nil
local shown = false -- client-side one-shot guard (the server is the real gate)
local gui: ScreenGui? = nil

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function applyUiScale(scale: UIScale)
	local camera = Workspace.CurrentCamera
	if camera == nil then
		return
	end
	local shortAxis = math.min(camera.ViewportSize.X, camera.ViewportSize.Y)
	if shortAxis <= 0 then
		return
	end
	scale.Scale = math.clamp(shortAxis / DESIGN_SHORT_AXIS_PX, UISCALE_MIN, UISCALE_MAX)
end

local function makeLine(text: string, color: Color3, order: number): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = `Line{order}`
	label.BackgroundTransparency = 1
	label.AutomaticSize = Enum.AutomaticSize.Y
	label.Size = UDim2.fromScale(1, 0)
	label.Font = Enum.Font.GothamBold
	label.TextSize = 17
	label.TextColor3 = color
	label.TextWrapped = true
	label.TextXAlignment = Enum.TextXAlignment.Center
	label.LayoutOrder = order
	label.Text = text
	return label
end

-- Kick off the guided step machine (safe registry lookup; nil = no-op).
local function startGuide()
	if registryRef == nil or type(registryRef.Get) ~= "function" then
		return
	end
	local guide = registryRef.Get("StarterGuideController")
	if type(guide) ~= "table" or type(guide.Begin) ~= "function" then
		return
	end
	local ok, err = pcall(guide.Begin)
	if not ok then
		warn(`[WelcomeController] StarterGuideController.Begin failed: {err}`)
	end
end

--------------------------------------------------------------------------------
-- Panel
--------------------------------------------------------------------------------

local function dismiss()
	local current = gui
	gui = nil
	if current ~= nil then
		current:Destroy()
	end
	startGuide()
end

local function buildPanel()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "WelcomeGui"
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = true
	screenGui.DisplayOrder = DISPLAY_ORDER

	-- Semi-transparent dark backdrop. Visual only — NOT Active, so no input lock.
	local backdrop = Instance.new("Frame")
	backdrop.Name = "Backdrop"
	backdrop.Size = UDim2.fromScale(1, 1)
	backdrop.BackgroundColor3 = COLOR_BACKDROP
	backdrop.BackgroundTransparency = 0.4
	backdrop.BorderSizePixel = 0
	backdrop.ZIndex = 1
	backdrop.Parent = screenGui

	local scale = Instance.new("UIScale")
	scale.Parent = backdrop
	applyUiScale(scale)
	local camera = Workspace.CurrentCamera
	if camera ~= nil then
		camera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
			applyUiScale(scale)
		end)
	end

	-- The centered card.
	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromOffset(PANEL_WIDTH_PX, 0)
	panel.AutomaticSize = Enum.AutomaticSize.Y
	panel.BackgroundColor3 = COLOR_PANEL
	panel.BackgroundTransparency = 0
	panel.BorderSizePixel = 0
	panel.ZIndex = 2
	panel.Parent = backdrop

	local panelCorner = Instance.new("UICorner")
	panelCorner.CornerRadius = UDim.new(0, 18)
	panelCorner.Parent = panel

	local panelStroke = Instance.new("UIStroke")
	panelStroke.Color = COLOR_TITLE
	panelStroke.Thickness = 2
	panelStroke.Transparency = 0.45
	panelStroke.Parent = panel

	-- Keep it from getting too wide on big screens.
	local widthCap = Instance.new("UISizeConstraint")
	widthCap.MaxSize = Vector2.new(PANEL_WIDTH_PX, math.huge)
	widthCap.Parent = panel

	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, 20)
	padding.PaddingBottom = UDim.new(0, 18)
	padding.PaddingLeft = UDim.new(0, 18)
	padding.PaddingRight = UDim.new(0, 18)
	padding.Parent = panel

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 12)
	layout.Parent = panel

	-- Title.
	local title = makeLine(GameConstants.WELCOME.TITLE, COLOR_TITLE, 1)
	title.TextSize = 30
	title.ZIndex = 2
	title.Parent = panel

	-- The "what to do" lines live in a height-capped ScrollingFrame so the
	-- GOT IT button below is ALWAYS reachable, even on a small landscape phone
	-- where the full card would otherwise be taller than the screen.
	local body = Instance.new("ScrollingFrame")
	body.Name = "Body"
	body.BackgroundTransparency = 1
	body.BorderSizePixel = 0
	body.Size = UDim2.fromScale(1, 0)
	body.AutomaticSize = Enum.AutomaticSize.Y
	body.AutomaticCanvasSize = Enum.AutomaticSize.Y
	body.CanvasSize = UDim2.new()
	body.ScrollingDirection = Enum.ScrollingDirection.Y
	body.ScrollBarThickness = 4
	body.ScrollBarImageTransparency = 0.4
	body.ZIndex = 2
	body.LayoutOrder = 2
	body.Parent = panel

	-- Design-space cap: the body scrolls past this, the title + button never do.
	local bodyCap = Instance.new("UISizeConstraint")
	bodyCap.MaxSize = Vector2.new(math.huge, 240)
	bodyCap.Parent = body

	local bodyLayout = Instance.new("UIListLayout")
	bodyLayout.FillDirection = Enum.FillDirection.Vertical
	bodyLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	bodyLayout.SortOrder = Enum.SortOrder.LayoutOrder
	bodyLayout.Padding = UDim.new(0, 12)
	bodyLayout.Parent = body

	-- One simple idea each. The FACTORY line is accented so the first thing
	-- they read is where to go.
	local lines: { { text: string, color: Color3 } } = {
		{ text = GameConstants.WELCOME.FACTORY, color = COLOR_FACTORY },
		{ text = GameConstants.WELCOME.BRAINROTS, color = COLOR_TEXT },
		{ text = GameConstants.WELCOME.LOCKER, color = COLOR_TEXT },
		{ text = GameConstants.WELCOME.PETS, color = COLOR_TEXT },
		{ text = GameConstants.WELCOME.PODIUM, color = COLOR_TEXT },
		{ text = GameConstants.WELCOME.HOUSE, color = COLOR_TEXT },
	}
	for index, line in lines do
		local label = makeLine(line.text, line.color, index)
		label.TextSize = if index == 1 then 19 else 16
		label.Font = if index == 1 then Enum.Font.GothamBold else Enum.Font.GothamMedium
		label.ZIndex = 2
		label.Parent = body
	end

	-- Big friendly GOT IT button (>= 44px tall).
	local dismissButton = Instance.new("TextButton")
	dismissButton.Name = "GotIt"
	dismissButton.Size = UDim2.new(1, 0, 0, DISMISS_HEIGHT_PX)
	dismissButton.BackgroundColor3 = COLOR_DISMISS
	dismissButton.BorderSizePixel = 0
	dismissButton.AutoButtonColor = true
	dismissButton.Font = Enum.Font.GothamBold
	dismissButton.TextSize = 20
	dismissButton.TextColor3 = COLOR_DISMISS_TEXT
	dismissButton.Text = GameConstants.WELCOME.DISMISS
	dismissButton.LayoutOrder = 3 -- title(1) -> body scroll(2) -> GOT IT(3), always visible
	dismissButton.ZIndex = 2
	dismissButton.Parent = panel
	local buttonCorner = Instance.new("UICorner")
	buttonCorner.CornerRadius = UDim.new(0, 12)
	buttonCorner.Parent = dismissButton

	dismissButton.Activated:Connect(dismiss)

	-- Soft fade-in.
	backdrop.BackgroundTransparency = 1
	panel.BackgroundTransparency = 1
	panelStroke.Transparency = 1
	TweenService:Create(backdrop, TweenInfo.new(FADE_SECONDS), { BackgroundTransparency = 0.4 }):Play()
	TweenService:Create(panel, TweenInfo.new(FADE_SECONDS), { BackgroundTransparency = 0 }):Play()
	TweenService:Create(panelStroke, TweenInfo.new(FADE_SECONDS), { Transparency = 0.45 }):Play()

	local playerGui = LocalPlayer:WaitForChild("PlayerGui")
	screenGui.Parent = playerGui
	gui = screenGui
end

--------------------------------------------------------------------------------
-- Remote handling
--------------------------------------------------------------------------------

local function onShowWelcome()
	if shown then
		return -- one-shot (the server is the real once-ever gate)
	end
	shown = true
	-- Small delay so the panel fades in after the player has settled into spawn.
	task.delay(GameConstants.WELCOME_SHOW_DELAY_SECONDS, function()
		if gui == nil then
			buildPanel()
		end
	end)
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function WelcomeController:Init(registry: any)
	-- Remotes.Get yields on the client, so the connection happens in Start. The
	-- registry is kept for the StarterGuideController hand-off on dismiss.
	registryRef = registry
end

function WelcomeController:Start()
	Remotes.GetEvent("ShowWelcome").OnClientEvent:Connect(onShowWelcome)
end

return WelcomeController
