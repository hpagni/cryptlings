--!strict
-- RESCUE THE BRAINROTS! — branded loading screen (ReplicatedFirst).
-- Runs before the world streams in: kills the default Roblox splash, shows the
-- title card with a hue-cycling rainbow title, a spinning crate, and rotating
-- goofy tips, then fades out once the game is loaded (minimum hold so the
-- brand reads even on instant loads).

local Players = game:GetService("Players")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local MIN_HOLD_SECONDS = 2.5
local FADE_SECONDS = 0.6
local TIP_INTERVAL = 2.2

local TIPS = {
	"Tip: Rarer Brainrots are BIGGER. Mythicals are basically furniture.",
	"Tip: Rainbow crates are 1-in-100. Tonight could be the night.",
	"Tip: The Defect can't open lockers. Probably.",
	"Tip: Shove a friend, steal their crate. They'll forgive you. Eventually.",
	"Tip: Crates spawn deeper = rarer. Be brave. Or don't, also fine.",
	"Tip: Clock in with your crew — nobody hauls a Gorillionaire alone.",
}

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

ReplicatedFirst:RemoveDefaultLoadingScreen()

local gui = Instance.new("ScreenGui")
gui.Name = "LoadingScreen"
gui.IgnoreGuiInset = true
gui.ResetOnSpawn = false
gui.DisplayOrder = 1000
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

local backdrop = Instance.new("Frame")
backdrop.Name = "Backdrop"
backdrop.Size = UDim2.fromScale(1, 1)
backdrop.BackgroundColor3 = Color3.fromRGB(16, 14, 20)
backdrop.BorderSizePixel = 0
backdrop.Parent = gui

local title = Instance.new("TextLabel")
title.Name = "Title"
title.AnchorPoint = Vector2.new(0.5, 0.5)
title.Position = UDim2.fromScale(0.5, 0.38)
title.Size = UDim2.fromScale(0.9, 0.16)
title.BackgroundTransparency = 1
title.Font = Enum.Font.GothamBlack
title.Text = "RESCUE THE BRAINROTS!"
title.TextScaled = true
title.TextColor3 = Color3.fromRGB(255, 255, 255)
title.TextStrokeTransparency = 0.4
title.Parent = backdrop

-- Rainbow gradient: the hue offset animates every frame (rarest-crate energy).
local gradient = Instance.new("UIGradient")
gradient.Color = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromHSV(0, 0.75, 1)),
	ColorSequenceKeypoint.new(0.25, Color3.fromHSV(0.25, 0.75, 1)),
	ColorSequenceKeypoint.new(0.5, Color3.fromHSV(0.5, 0.75, 1)),
	ColorSequenceKeypoint.new(0.75, Color3.fromHSV(0.75, 0.75, 1)),
	ColorSequenceKeypoint.new(1, Color3.fromHSV(1, 0.75, 1)),
})
gradient.Parent = title

local subtitle = Instance.new("TextLabel")
subtitle.Name = "Subtitle"
subtitle.AnchorPoint = Vector2.new(0.5, 0.5)
subtitle.Position = UDim2.fromScale(0.5, 0.5)
subtitle.Size = UDim2.fromScale(0.8, 0.05)
subtitle.BackgroundTransparency = 1
subtitle.Font = Enum.Font.GothamBold
subtitle.Text = "Night shift starts soon — grab the crates, save the goofy ones."
subtitle.TextScaled = true
subtitle.TextColor3 = Color3.fromRGB(200, 196, 210)
subtitle.Parent = backdrop

-- Spinning "crate": a hazard-striped square, pure GUI (no image assets).
local crate = Instance.new("Frame")
crate.Name = "Crate"
crate.AnchorPoint = Vector2.new(0.5, 0.5)
crate.Position = UDim2.fromScale(0.5, 0.66)
crate.Size = UDim2.fromOffset(56, 56)
crate.BackgroundColor3 = Color3.fromRGB(235, 190, 52)
crate.BorderSizePixel = 0
crate.Parent = backdrop

local crateStripe = Instance.new("Frame")
crateStripe.Name = "Stripe"
crateStripe.AnchorPoint = Vector2.new(0.5, 0.5)
crateStripe.Position = UDim2.fromScale(0.5, 0.5)
crateStripe.Size = UDim2.fromScale(1, 0.28)
crateStripe.BackgroundColor3 = Color3.fromRGB(34, 32, 38)
crateStripe.BorderSizePixel = 0
crateStripe.Parent = crate

local tip = Instance.new("TextLabel")
tip.Name = "Tip"
tip.AnchorPoint = Vector2.new(0.5, 1)
tip.Position = UDim2.fromScale(0.5, 0.92)
tip.Size = UDim2.fromScale(0.85, 0.045)
tip.BackgroundTransparency = 1
tip.Font = Enum.Font.Gotham
tip.Text = TIPS[1]
tip.TextScaled = true
tip.TextColor3 = Color3.fromRGB(150, 146, 160)
tip.Parent = backdrop

gui.Parent = playerGui

-- Animation loop: gradient hue scroll + crate spin + tip rotation.
local startClock = os.clock()
local alive = true
local heartbeat = RunService.Heartbeat:Connect(function()
	local t = os.clock() - startClock
	gradient.Offset = Vector2.new((t * 0.35) % 1, 0)
	crate.Rotation = (t * 120) % 360
	local tipIndex = (math.floor(t / TIP_INTERVAL) % #TIPS) + 1
	tip.Text = TIPS[tipIndex]
end)

task.spawn(function()
	-- Hold until both the world is loaded and the brand has had its moment.
	while not game:IsLoaded() do
		game.Loaded:Wait()
	end
	local elapsed = os.clock() - startClock
	if elapsed < MIN_HOLD_SECONDS then
		task.wait(MIN_HOLD_SECONDS - elapsed)
	end
	if not alive then
		return
	end
	alive = false

	local fade = TweenService:Create(backdrop, TweenInfo.new(FADE_SECONDS), { BackgroundTransparency = 1 })
	for _, child in backdrop:GetChildren() do
		if child:IsA("TextLabel") then
			TweenService
				:Create(child, TweenInfo.new(FADE_SECONDS), { TextTransparency = 1, TextStrokeTransparency = 1 })
				:Play()
		elseif child:IsA("Frame") then
			TweenService:Create(child, TweenInfo.new(FADE_SECONDS), { BackgroundTransparency = 1 }):Play()
		end
	end
	TweenService:Create(crateStripe, TweenInfo.new(FADE_SECONDS), { BackgroundTransparency = 1 }):Play()
	fade:Play()
	fade.Completed:Wait()
	heartbeat:Disconnect()
	gui:Destroy()
end)
