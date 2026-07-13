--!strict
-- CRYPTLINGS: NIGHT SHIFT — HeroFXController (Addendum 1 Change 3, plan R2
-- WP3.1, AC-3). Dresses and spins the 1-3 oversized hero brainrot figures
-- fronting the Factory. WallBuilder ships them server-built and STATIC
-- (tag "HeroFigure", attrs CryptlingId / Rarity / HeroIndex, Neon rarity ring
-- already on the plinth); everything that moves or glows happens here,
-- client-side — the server never writes hero CFrames.
--
--   * Spin: ONE frame loop, model:PivotTo(base * CFrame.Angles(0, yaw, 0)) at
--     HERO.SPIN_DEG_PER_SEC (11 deg/s — half the podium speed: monuments read
--     slow) with a HeroIndex-derived 120-degree phase offset so the three
--     never sync. NO bob ever — bob is the lightweight-pickup affordance and
--     reads floaty on oversized figures. Static beyond the house animate
--     radius, same gate as the podium displays.
--   * Tier signature: RarityFX.Apply(figure, def, {noLights = true,
--     noMotion = true}) — zero PointLights attached (the lobby Light budget
--     is FULL at 50/50; the server-built Neon ring is the guaranteed rarity
--     read), and a Mythical hero keeps its hue-cycle with the bob/spin zeroed
--     (this controller owns the yaw).
--   * Highlight accent: outline-only (FillTransparency 1), tier color,
--     DepthMode Occluded — DESTROYED on teardown, never disabled (disabled
--     Highlights still consume one of the engine's slots).
--   * Sparkles: one ParticleEmitter per hero at HERO.SPARKLE_RATE (10/s,
--     house sparkles_main.dds — the freed fountain particle budget), gated to
--     the RARITY_FX_RADIUS like every other rarity emitter.
--   * No labels (Addendum 2 R3-2): figures are text-free; the wall carries
--     the names. Rarity reads via the Neon ring + Highlight at every quality.
--
-- Public API (Controllers.Get("HeroFXController")):
--   HeroFXController.GetActiveHeroCount() -> number  -- QA/debug

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local LobbyConfig = require(Shared:WaitForChild("Config"):WaitForChild("LobbyConfig"))
local RarityFX = require(Shared:WaitForChild("Config"):WaitForChild("RarityFX"))
local RarityTable = require(Shared:WaitForChild("Config"):WaitForChild("RarityTable"))

--------------------------------------------------------------------------------
-- Tuning (hero constants of record live in LobbyConfig.HERO — SOP §9)
--------------------------------------------------------------------------------

-- 3D contract (produced by WallBuilder, Addendum 1 Change 3).
local TAG_HERO = "HeroFigure"
local ATTR_CRYPTLING_ID = "CryptlingId"
local ATTR_RARITY = "Rarity"
local ATTR_HERO_INDEX = "HeroIndex"
-- Client-local dedupe stamp: a re-tagged (not re-streamed) figure keeps the
-- FX it already wears instead of stacking a second set.
local ATTR_FX_APPLIED = "HeroFXApplied"

local HERO = LobbyConfig.HERO
local SPIN_DEGREES_PER_SECOND = HERO.SPIN_DEG_PER_SEC -- 11
local PHASE_DEGREES = HERO.PHASE_DEGREES -- 120
local ANIMATE_RADIUS_STUDS = LobbyConfig.DISPLAY_ANIMATE_RADIUS_STUDS -- 120
local FX_RADIUS_STUDS = LobbyConfig.RARITY_FX_RADIUS_STUDS -- 50

-- Emitter Enabled flips are throttled — they never need frame accuracy.
local FX_GATE_SECONDS = 0.25

local SPARKLE_TEXTURE = "rbxasset://textures/particles/sparkles_main.dds"

local COLOR_FALLBACK = Color3.fromRGB(178, 178, 178)

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

type HeroEntry = {
	model: Model,
	base: CFrame, -- upright pivot WallBuilder leaves at the podium base
	basePosition: Vector3,
	phaseDegrees: number,
	highlight: Highlight?,
	emitters: { ParticleEmitter },
	fxEnabled: boolean,
	animating: boolean,
}

local HeroFXController = {}

local heroes: { [Model]: HeroEntry } = {}
local fxGateAccumulator = 0

--------------------------------------------------------------------------------
-- Dressing helpers
--------------------------------------------------------------------------------

local function tierColorOf(rarity: string?): Color3
	local color = if rarity ~= nil then (RarityTable.RARITY_COLORS :: any)[rarity] else nil
	return if typeof(color) == "Color3" then color else COLOR_FALLBACK
end

local function largestPartOf(model: Model): BasePart?
	local best: BasePart? = nil
	local bestVolume = -1
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			local size = descendant.Size
			local volume = size.X * size.Y * size.Z
			if volume > bestVolume then
				bestVolume = volume
				best = descendant
			end
		end
	end
	return best
end

-- Hero sparkle garnish (HERO.SPARKLE_RATE inherits the plaza budget the
-- fountain freed — Change 8); the Neon ring stays the guaranteed read when
-- low graphics quality throttles emitters.
local function makeSparkles(anchor: BasePart, color: Color3): ParticleEmitter
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "HeroSparkles"
	emitter.Texture = SPARKLE_TEXTURE
	emitter.Color = ColorSequence.new(color)
	emitter.Rate = HERO.SPARKLE_RATE
	emitter.LightEmission = 1
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.6),
		NumberSequenceKeypoint.new(1, 0.15),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.2),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Lifetime = NumberRange.new(HERO.SPARKLE_LIFETIME_MIN, HERO.SPARKLE_LIFETIME_MAX)
	emitter.Speed = NumberRange.new(HERO.SPARKLE_SPEED_MIN, HERO.SPARKLE_SPEED_MAX)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Enabled = false -- the frame loop gates by camera distance
	emitter.Parent = anchor
	return emitter
end

--------------------------------------------------------------------------------
-- Hero lifecycle
--------------------------------------------------------------------------------

local function watchHero(instance: Instance)
	if not instance:IsA("Model") then
		return
	end
	if heroes[instance] ~= nil then
		return
	end

	local indexAttr = instance:GetAttribute(ATTR_HERO_INDEX)
	local heroIndex: number = if type(indexAttr) == "number" then indexAttr else 1
	local idAttr = instance:GetAttribute(ATTR_CRYPTLING_ID)
	local def: any = if type(idAttr) == "string" then RarityTable.GetCryptling(idAttr) else nil
	local rarityAttr = instance:GetAttribute(ATTR_RARITY)
	local rarity: string? = if type(rarityAttr) == "string"
		then rarityAttr
		elseif type(def) == "table" and type(def.rarity) == "string" then def.rarity
		else nil
	local color = tierColorOf(rarity)

	local entry: HeroEntry = {
		model = instance,
		base = instance:GetPivot(),
		basePosition = instance:GetPivot().Position,
		phaseDegrees = (heroIndex - 1) * PHASE_DEGREES,
		highlight = nil,
		emitters = {},
		fxEnabled = false,
		animating = false,
	}
	heroes[instance] = entry

	-- Tier dressing lives on the Figure sub-model so the plinth/ring stay
	-- clean; everything degrades gracefully if the figure is missing.
	local figure = instance:FindFirstChild("Figure")
	if figure ~= nil and figure:IsA("Model") then
		if figure:GetAttribute(ATTR_FX_APPLIED) ~= true then
			figure:SetAttribute(ATTR_FX_APPLIED, true)
			if def ~= nil then
				-- AC-3: the noLights path — zero PointLights, Light count
				-- stays 50; noMotion keeps a Mythical hue-cycle but this
				-- controller alone owns the pivot.
				RarityFX.Apply(figure, def, { noLights = true, noMotion = true })
			end
			local anchor = largestPartOf(figure)
			if anchor ~= nil then
				makeSparkles(anchor, color)
			end
		end

		-- Collect every rarity emitter (ours + RarityFX's) for distance gating.
		for _, descendant in figure:GetDescendants() do
			if descendant:IsA("ParticleEmitter") then
				descendant.Enabled = false
				table.insert(entry.emitters, descendant)
			end
		end

		local highlight = Instance.new("Highlight")
		highlight.Name = "HeroHighlight"
		highlight.Adornee = figure
		highlight.FillTransparency = 1 -- outline only
		highlight.OutlineColor = color
		highlight.OutlineTransparency = HERO.HIGHLIGHT_OUTLINE_TRANSPARENCY
		highlight.DepthMode = Enum.HighlightDepthMode.Occluded
		highlight.Parent = figure
		entry.highlight = highlight
	end
end

local function unwatchHero(instance: Instance)
	if not instance:IsA("Model") then
		return
	end
	local entry = heroes[instance]
	if entry == nil then
		return
	end
	heroes[instance] = nil

	-- Destroy, never Disable: a disabled Highlight still consumes one of the
	-- engine's adornment slots (AC-3).
	local highlight = entry.highlight
	if highlight ~= nil then
		highlight:Destroy()
	end
	-- Park the figure at its rest pose so a re-tag (without a re-stream)
	-- captures the same upright base next time around.
	pcall(function()
		instance:PivotTo(entry.base)
	end)
end

--------------------------------------------------------------------------------
-- The ONE frame loop: yaw-only spin within the animate radius (phase-offset,
-- never synced, no bob), emitter gating within the FX radius
--------------------------------------------------------------------------------

local function onFrame(deltaTime: number)
	local camera = Workspace.CurrentCamera
	if camera == nil then
		return
	end
	local cameraPosition = camera.CFrame.Position
	local now = os.clock()

	fxGateAccumulator += deltaTime
	local gateFx = fxGateAccumulator >= FX_GATE_SECONDS
	if gateFx then
		fxGateAccumulator = 0
	end

	for _, entry in heroes do
		local distance = (entry.basePosition - cameraPosition).Magnitude
		if distance <= ANIMATE_RADIUS_STUDS then
			local yaw = math.rad(now * SPIN_DEGREES_PER_SECOND + entry.phaseDegrees)
			entry.model:PivotTo(entry.base * CFrame.Angles(0, yaw, 0))
			entry.animating = true
		elseif entry.animating then
			entry.model:PivotTo(entry.base) -- park in the rest pose
			entry.animating = false
		end

		if gateFx and #entry.emitters > 0 then
			local enable = distance <= FX_RADIUS_STUDS
			if enable ~= entry.fxEnabled then
				entry.fxEnabled = enable
				for _, emitter in entry.emitters do
					emitter.Enabled = enable
				end
			end
		end
	end
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

function HeroFXController.GetActiveHeroCount(): number
	local count = 0
	for _ in heroes do
		count += 1
	end
	return count
end

--------------------------------------------------------------------------------
-- Loader lifecycle
--------------------------------------------------------------------------------

function HeroFXController:Init()
	-- Connections only (Init must not yield). Heroes tagged before Start runs
	-- are picked up by the Start sweep below.
	CollectionService:GetInstanceAddedSignal(TAG_HERO):Connect(function(instance: Instance)
		-- Deferred so a just-streamed hero's attributes replicate before we read.
		task.defer(watchHero, instance)
	end)
	CollectionService:GetInstanceRemovedSignal(TAG_HERO):Connect(unwatchHero)
end

function HeroFXController:Start()
	-- Initial sweep: the Factory front may already be streamed in.
	for _, instance in CollectionService:GetTagged(TAG_HERO) do
		watchHero(instance)
	end

	RunService.Heartbeat:Connect(onFrame)
end

return HeroFXController
