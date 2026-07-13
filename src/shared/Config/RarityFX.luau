--!strict
-- CRYPTLINGS: NIGHT SHIFT — RarityFX (collectible redesign).
-- Per-tier visual signatures applied to an ASSEMBLED recipe model (the parts
-- already exist; this module only decorates them). One entry point:
--
--   RarityFX.Apply(model, def, options?)
--     model:   Model containing the rendered recipe BaseParts
--     def:     the RarityTable cryptling def (def.rarity picks the signature,
--              RARITY_COLORS picks the tint)
--     options: { static: boolean?, noLights: boolean?, noMotion: boolean? }
--              static=true is the ViewportFrame mode: no Tweens, no
--              ParticleEmitters, no run loops; colors/lights applied once.
--              noLights=true skips every makeLight site (lobby Light budget,
--              Addendum 1 Change 3); noMotion=true keeps the Mythical
--              hue-cycle but never calls PivotTo. nil options = full FX.
--
-- Tier signatures:
--   Common/Uncommon  nothing (the recipe's own colors carry it)
--   Rare             faint tier-color PointLight on the largest part
--   Epic+            tier-color sparkle ParticleEmitter (rate ~3.5)
--   Legendary        + pulsing red PointLight (0.5 <-> 2.2, 1.2s loop) + embers
--   Godly            + two gold lights, 3 neon god-ray cylinders, gold fountain
--   Mythical         hue-cycle ALL parts (phase-offset, 6s cycle), hue-cycling
--                    PointLight (range 14), neon halo ring, slow bob+spin
--                    (loops stop themselves once the model is unparented)
--
-- IMPORTANT: unlike its Shared/Config siblings (GameConstants, RarityTable)
-- this module is NOT lune-pure — it uses Instance/TweenService/task and must
-- only be required from Roblox runtimes (client + server). It lives here
-- because it is config-driven presentation glued directly to RarityTable.
-- FX are cosmetic: every step is guarded and Apply never throws.

local TweenService = game:GetService("TweenService")

local RarityTable = require(script.Parent:WaitForChild("RarityTable"))

local RarityFX = {}

--------------------------------------------------------------------------------
-- Tuning
--------------------------------------------------------------------------------

local SPARKLE_TEXTURE = "rbxasset://textures/particles/sparkles_main.dds"

local RARE_LIGHT_BRIGHTNESS = 0.6
local RARE_LIGHT_RANGE = 8

local SPARKLE_RATE = 3.5
local EMBER_RATE = 6
local FOUNTAIN_RATE = 12

local LEGENDARY_PULSE_MIN = 0.5
local LEGENDARY_PULSE_MAX = 2.2
local LEGENDARY_PULSE_SECONDS = 1.2

local GODRAY_COUNT = 3
local GODRAY_TRANSPARENCY = 0.55

local MYTHIC_CYCLE_SECONDS = 6 -- full hue rotation
local MYTHIC_LIGHT_RANGE = 14
local MYTHIC_STEP_SECONDS = 0.08 -- hue/bob loop cadence (cheap task loop)
local MYTHIC_BOB_STUDS = 0.25
local MYTHIC_SPIN_RAD_PER_SECOND = 0.5

local COLOR_GOLD = Color3.fromRGB(235, 190, 52)
local COLOR_FALLBACK = Color3.fromRGB(178, 178, 178)

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function tierColor(rarity: string?): Color3
	local color = if rarity ~= nil then (RarityTable.RARITY_COLORS :: any)[rarity] else nil
	if typeof(color) == "Color3" then
		return color
	end
	return COLOR_FALLBACK
end

local function getParts(model: Model): { BasePart }
	local parts: { BasePart } = {}
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			table.insert(parts, descendant)
		end
	end
	return parts
end

local function largestPart(parts: { BasePart }): BasePart?
	local best: BasePart? = nil
	local bestVolume = -1
	for _, part in parts do
		local size = part.Size
		local volume = size.X * size.Y * size.Z
		if volume > bestVolume then
			bestVolume = volume
			best = part
		end
	end
	return best
end

local function modelBounds(model: Model): (CFrame, Vector3)
	local ok, cf, size = pcall(function()
		return model:GetBoundingBox()
	end)
	if ok and typeof(cf) == "CFrame" and typeof(size) == "Vector3" then
		return cf, size
	end
	return CFrame.new(0, 2, 0), Vector3.new(2, 4, 2)
end

local noLightsActive = false -- per-Apply switch: skip every makeLight site
local noMotionActive = false -- per-Apply switch: Mythical hue-cycle sans PivotTo

local function makeLight(parent: BasePart, color: Color3, brightness: number, range: number): PointLight?
	if noLightsActive then
		return nil
	end
	local light = Instance.new("PointLight")
	light.Color = color
	light.Brightness = brightness
	light.Range = range
	light.Shadows = false
	light.Parent = parent
	return light
end

local function makeEmitter(parent: BasePart, color: Color3, rate: number): ParticleEmitter
	local emitter = Instance.new("ParticleEmitter")
	emitter.Texture = SPARKLE_TEXTURE
	emitter.Color = ColorSequence.new(color)
	emitter.Rate = rate
	emitter.LightEmission = 1
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.2),
		NumberSequenceKeypoint.new(1, 0.05),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.2),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Lifetime = NumberRange.new(0.8, 1.6)
	emitter.Speed = NumberRange.new(0.4, 1.2)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Parent = parent
	return emitter
end

-- Decorative anchored part inside the model (rays, halo). Never collides,
-- never blocks queries — pure dressing.
local function makeFxPart(model: Model, name: string, size: Vector3, cframe: CFrame, color: Color3): BasePart
	local part = Instance.new("Part")
	part.Name = name
	part.Shape = Enum.PartType.Cylinder
	part.Size = size
	part.CFrame = cframe
	part.Color = color
	part.Material = Enum.Material.Neon
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = model
	return part
end

--------------------------------------------------------------------------------
-- Tier signatures
--------------------------------------------------------------------------------

local function applyRare(anchor: BasePart, color: Color3)
	makeLight(anchor, color, RARE_LIGHT_BRIGHTNESS, RARE_LIGHT_RANGE)
end

local function applyEpic(anchor: BasePart, color: Color3, static: boolean)
	if not static then
		makeEmitter(anchor, color, SPARKLE_RATE)
	end
end

local function applyLegendary(anchor: BasePart, color: Color3, static: boolean)
	applyEpic(anchor, color, static)
	if static then
		-- Viewport mode: a fixed mid-pulse glow instead of the tween loop.
		makeLight(anchor, color, (LEGENDARY_PULSE_MIN + LEGENDARY_PULSE_MAX) / 2, 10)
		return
	end
	local light = makeLight(anchor, color, LEGENDARY_PULSE_MIN, 10)
	if light ~= nil then
		TweenService:Create(
			light,
			TweenInfo.new(LEGENDARY_PULSE_SECONDS, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
			{ Brightness = LEGENDARY_PULSE_MAX }
		):Play()
	end
	local embers = makeEmitter(anchor, color, EMBER_RATE)
	embers.Speed = NumberRange.new(1, 2.5)
	embers.Acceleration = Vector3.new(0, 2.5, 0) -- embers drift upward
	embers.SpreadAngle = Vector2.new(35, 35)
	embers.EmissionDirection = Enum.NormalId.Top
end

local function applyGodly(model: Model, anchor: BasePart, color: Color3, static: boolean)
	applyEpic(anchor, color, static)
	-- Gold light x2: core glow on the body + a crown glow above it.
	makeLight(anchor, COLOR_GOLD, 1.2, 12)
	local boundsCF, boundsSize = modelBounds(model)
	local topCenter = boundsCF.Position + Vector3.new(0, boundsSize.Y / 2 + 0.4, 0)

	-- God-rays: thin neon cylinders fanning outward above the model.
	local rayLength = math.max(boundsSize.Y * 0.9, 2.5)
	local crown: BasePart? = nil
	for index = 1, GODRAY_COUNT do
		local yaw = (index - 1) / GODRAY_COUNT * 360
		local rayCF = CFrame.new(topCenter)
			* CFrame.Angles(0, math.rad(yaw), 0)
			* CFrame.Angles(0, 0, math.rad(55)) -- tilt the cylinder's X axis up-and-out
			* CFrame.new(rayLength / 2, 0, 0)
		local ray = makeFxPart(model, `GodRay{index}`, Vector3.new(rayLength, 0.15, 0.15), rayCF, COLOR_GOLD)
		ray.Transparency = GODRAY_TRANSPARENCY
		crown = crown or ray
	end
	if crown ~= nil then
		makeLight(crown, COLOR_GOLD, 1.2, 12) -- the second gold light, up top
	end

	if not static then
		local fountain = makeEmitter(anchor, COLOR_GOLD, FOUNTAIN_RATE)
		fountain.Speed = NumberRange.new(4, 7)
		fountain.Acceleration = Vector3.new(0, -6, 0) -- up, arc, fall: a fountain
		fountain.SpreadAngle = Vector2.new(20, 20)
		fountain.EmissionDirection = Enum.NormalId.Top
		fountain.Lifetime = NumberRange.new(1, 1.8)
	end
end

local function applyMythical(model: Model, parts: { BasePart }, anchor: BasePart, color: Color3, static: boolean)
	applyEpic(anchor, color, static)
	local light = makeLight(anchor, color, 1.2, MYTHIC_LIGHT_RANGE)

	-- Floating neon halo ring above the model.
	local boundsCF, boundsSize = modelBounds(model)
	local haloDiameter = math.max(boundsSize.X, boundsSize.Z) * 0.8
	local haloCF = CFrame.new(boundsCF.Position + Vector3.new(0, boundsSize.Y / 2 + 0.7, 0))
		* CFrame.Angles(0, 0, math.rad(90)) -- cylinder axis vertical = flat ring
	local halo = makeFxPart(model, "MythicHalo", Vector3.new(0.15, haloDiameter, haloDiameter), haloCF, color)
	halo.Transparency = 0.35

	local count = math.max(#parts, 1)
	if static then
		-- Viewport mode: one frozen frame of the rainbow, phase-offset per part.
		for index, part in parts do
			part.Color = Color3.fromHSV((index - 1) / count, 0.7, 1)
		end
		return
	end

	-- Live mode: hue-cycle every part (phase-offset), the light and the halo;
	-- slow bob+spin around the model's pivot. One loop per model; it exits as
	-- soon as the model leaves the world.
	local noMotion = noMotionActive -- captured: this loop outlives the Apply call
	local basePivot = model:GetPivot()
	local startedAt = os.clock()
	task.spawn(function()
		while model.Parent ~= nil do
			local elapsed = os.clock() - startedAt
			local phase = (elapsed / MYTHIC_CYCLE_SECONDS) % 1
			for index, part in parts do
				if part.Parent ~= nil then
					part.Color = Color3.fromHSV((phase + (index - 1) / count) % 1, 0.7, 1)
				end
			end
			if light ~= nil then
				light.Color = Color3.fromHSV(phase, 0.7, 1)
			end
			halo.Color = Color3.fromHSV((phase + 0.5) % 1, 0.7, 1)

			if not noMotion then
				model:PivotTo(
					basePivot
						* CFrame.new(0, (math.sin(elapsed * 1.2) + 1) * 0.5 * MYTHIC_BOB_STUDS, 0)
						* CFrame.Angles(0, elapsed * MYTHIC_SPIN_RAD_PER_SECOND, 0)
				)
			end
			task.wait(MYTHIC_STEP_SECONDS)
		end
	end)
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

type ApplyOptions = { static: boolean?, noLights: boolean?, noMotion: boolean? }

-- Applies the def's tier signature to an assembled recipe model. Never errors:
-- bad input is a no-op, and each signature is pcall-fenced (FX must never take
-- a renderer down).
function RarityFX.Apply(model: Model, def: any, options: ApplyOptions?)
	if typeof(model) ~= "Instance" or not model:IsA("Model") then
		return
	end
	local rarity: string? = if type(def) == "table" and type(def.rarity) == "string" then def.rarity else nil
	if rarity == nil or rarity == "Common" or rarity == "Uncommon" then
		return -- no tier signature below Rare
	end
	local static = options ~= nil and options.static == true
	noLightsActive = options ~= nil and options.noLights == true
	noMotionActive = options ~= nil and options.noMotion == true

	local parts = getParts(model)
	local anchor = largestPart(parts)
	if anchor == nil then
		return
	end
	local color = tierColor(rarity)

	pcall(function()
		if rarity == "Rare" then
			applyRare(anchor, color)
		elseif rarity == "Epic" then
			applyEpic(anchor, color, static)
		elseif rarity == "Legendary" then
			applyLegendary(anchor, color, static)
		elseif rarity == "Godly" then
			applyGodly(model, anchor, color, static)
		elseif rarity == "Mythical" then
			applyMythical(model, parts, anchor, color, static)
		end
	end)
end

return table.freeze(RarityFX)
