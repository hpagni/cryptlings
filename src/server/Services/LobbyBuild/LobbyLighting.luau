--!strict
-- CRYPTLINGS: NIGHT SHIFT — LobbyLighting: the SINGLE owner of global lighting
-- (LOBBY_SOP §2; plan WP2.5/WP4.2). `Apply()` writes every §2.1 Lighting
-- service value from LobbyConfig, retires legacy fog in favor of the §2.2
-- Atmosphere (FogEnd 220 would clip the ~700-stud street), and find-or-creates
-- the sky + post FX instances, so repeat calls are idempotent:
--   * HubService calls Apply() once at lobby build (Wave 3);
--   * FloorGenService delegates here on every shift instead of stomping
--     ClockTime 0 / FogEnd 220 over the street (WP4.2).
-- No other module may write Lighting globals. Per-floor local flicker lights
-- stay in FloorGenService — those are Light instances, not Lighting globals.

local LightingService = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local LobbyConfig = require(Shared:WaitForChild("Config"):WaitForChild("LobbyConfig"))

local LobbyLighting = {}

-- LobbyConfig stores colors as lune-safe frozen { R, G, B } 0-255 tables.
type RGB = { R: number, G: number, B: number }

local function toColor3(color: RGB): Color3
	return Color3.fromRGB(color.R, color.G, color.B)
end

--------------------------------------------------------------------------------
-- Find-or-create helpers (idempotence: re-Apply() never stacks duplicates)
--------------------------------------------------------------------------------

local function ensureAtmosphere(): Atmosphere
	local existing = LightingService:FindFirstChildOfClass("Atmosphere")
	if existing ~= nil then
		return existing
	end
	local atmosphere = Instance.new("Atmosphere")
	atmosphere.Name = "LobbyAtmosphere"
	atmosphere.Parent = LightingService
	return atmosphere
end

local function ensureSky(): Sky
	local existing = LightingService:FindFirstChildOfClass("Sky")
	if existing ~= nil then
		return existing
	end
	local sky = Instance.new("Sky")
	sky.Name = "LobbySky" -- default skybox textures (SOP §2.3)
	sky.Parent = LightingService
	return sky
end

local function ensureBloom(): BloomEffect
	local existing = LightingService:FindFirstChildOfClass("BloomEffect")
	if existing ~= nil then
		return existing
	end
	local bloom = Instance.new("BloomEffect")
	bloom.Name = "LobbyBloom"
	bloom.Parent = LightingService
	return bloom
end

local function ensureColorCorrection(): ColorCorrectionEffect
	local existing = LightingService:FindFirstChildOfClass("ColorCorrectionEffect")
	if existing ~= nil then
		return existing
	end
	local colorCorrection = Instance.new("ColorCorrectionEffect")
	colorCorrection.Name = "LobbyColorCorrection"
	colorCorrection.Parent = LightingService
	return colorCorrection
end

--------------------------------------------------------------------------------
-- Apply
--------------------------------------------------------------------------------

-- Writes the full SOP §2 night look. Safe to call any number of times.
function LobbyLighting.Apply()
	local config = LobbyConfig.LIGHTING

	-- §2.1 Technology: ShadowMap, never Future (Future tanks low-end mobile).
	-- The property is plugin-security on live servers, so this write only
	-- lands where scripts may set it (Studio test runs); the built place file
	-- pins ShadowMap as the shipped value. pcall keeps live boot warn-free.
	pcall(function()
		local lighting: any = LightingService
		lighting.Technology = (Enum.Technology :: any)[config.TECHNOLOGY]
	end)

	-- §2.1 Lighting service values.
	LightingService.GlobalShadows = config.GLOBAL_SHADOWS
	LightingService.ClockTime = config.CLOCK_TIME
	LightingService.GeographicLatitude = config.GEOGRAPHIC_LATITUDE
	LightingService.Brightness = config.BRIGHTNESS
	LightingService.Ambient = toColor3(config.AMBIENT)
	LightingService.OutdoorAmbient = toColor3(config.OUTDOOR_AMBIENT)
	LightingService.ExposureCompensation = config.EXPOSURE_COMPENSATION

	-- §2.2 Legacy fog is dead: zero it back to engine defaults (FogStart 0 /
	-- FogEnd 100000 = effectively no fog) before the Atmosphere takes over.
	-- Any FloorGen-era FogEnd 220 write is undone right here.
	LightingService.FogStart = 0
	LightingService.FogEnd = 100_000
	LightingService.FogColor = Color3.fromRGB(192, 192, 192)

	-- §2.2 Atmosphere supersedes fog.
	local atmosphere = ensureAtmosphere()
	atmosphere.Density = LobbyConfig.ATMOSPHERE.DENSITY
	atmosphere.Offset = LobbyConfig.ATMOSPHERE.OFFSET
	atmosphere.Color = toColor3(LobbyConfig.ATMOSPHERE.COLOR)
	atmosphere.Decay = toColor3(LobbyConfig.ATMOSPHERE.DECAY)
	atmosphere.Haze = LobbyConfig.ATMOSPHERE.HAZE
	atmosphere.Glare = LobbyConfig.ATMOSPHERE.GLARE

	-- §2.3 Sky: default skybox at sunset clock time — no stars, sun/moon disc hidden
	-- (no blinding ball); the orange horizon comes from the Atmosphere haze.
	local sky = ensureSky()
	sky.StarCount = LobbyConfig.SKY.STAR_COUNT
	sky.MoonAngularSize = LobbyConfig.SKY.MOON_ANGULAR_SIZE
	sky.CelestialBodiesShown = LobbyConfig.SKY.CELESTIAL_BODIES_SHOWN

	-- §2.4 Post FX.
	local bloom = ensureBloom()
	bloom.Intensity = LobbyConfig.BLOOM.INTENSITY
	bloom.Size = LobbyConfig.BLOOM.SIZE
	bloom.Threshold = LobbyConfig.BLOOM.THRESHOLD
	bloom.Enabled = true

	local colorCorrection = ensureColorCorrection()
	colorCorrection.Contrast = LobbyConfig.COLOR_CORRECTION.CONTRAST
	colorCorrection.Saturation = LobbyConfig.COLOR_CORRECTION.SATURATION
	colorCorrection.TintColor = toColor3(LobbyConfig.COLOR_CORRECTION.TINT)
	colorCorrection.Enabled = true
end

return LobbyLighting
