--!strict
-- CRYPTLINGS: NIGHT SHIFT — PartKit: shared greybox build helpers for the
-- street-lobby builders (LOBBY_SOP §4.2, §6.1, §10, §11.1).
--
-- This is the ONE place lobby greybox primitives are made. Every builder in
-- LobbyBuild/ (StreetBuilder, FactoryBuilder, ShopBuilder, PlazaBuilder,
-- ComingSoonBuilder, QueuePadBuilder, WallBuilder, DecorBuilder) constructs
-- its Parts, signs, billboards, marquee letters, and lights through these
-- helpers so the SOP performance rules are enforced structurally:
--   * every primitive is Anchored with Smooth surfaces;
--   * the `decor` flag applies the SOP §10 display-part preset in one move
--     (CanCollide/CanTouch/CanQuery = false + CastShadow = false);
--   * every SurfaceGui/BillboardGui ships with LightInfluence 0 and
--     Brightness 2 (the #1 night-sign bug, SOP §11.1);
--   * every light made here has Shadows = false enforced and is registered
--     against the module-level LightBudget tally so HubService can assert the
--     streamed-in total stays ≤ LobbyConfig.LIGHT_BUDGET (50) after the build.
--
-- Geometry-only module by contract: no signals, no connections, no loops over
-- time, no player logic — pure construction invoked by the Wave-3 HubService
-- orchestrator and its builder modules.
--
-- Marquee letters: MakeBlockLetters renders 3D Neon block letters from a
-- built-in 5-row × 3-column segment font (2–4 Parts per letter; diagonal
-- strokes are rotated Parts). Glyph coverage is exactly what the SOP's
-- verbatim marquee strings need — "Factory", "Coming Soon", "Shop" — mapped
-- case-insensitively to uppercase glyphs.

local PartKit = {}

--------------------------------------------------------------------------------
-- Palette defaults (builders pass explicit colors for everything thematic;
-- these are only the fallbacks).
--------------------------------------------------------------------------------

local COLOR_GREYBOX = Color3.fromRGB(76, 76, 82)
local COLOR_TEXT_WARM = Color3.fromRGB(255, 236, 200) -- SOP §11.1 warm-white sign text
local COLOR_LIGHT_WARM = Color3.fromRGB(255, 214, 170) -- SOP §2.5 lamp color
local COLOR_STROKE = Color3.fromRGB(0, 0, 0)

--------------------------------------------------------------------------------
-- Types
--------------------------------------------------------------------------------

export type PartProps = {
	color: Color3?,
	material: Enum.Material?,
	transparency: number?,
	-- SOP §10 display/decor preset: CanCollide/CanTouch/CanQuery = false and
	-- CastShadow = false in one flag. Explicit fields below override it.
	decor: boolean?,
	canCollide: boolean?,
	canTouch: boolean?,
	canQuery: boolean?,
	castShadow: boolean?,
}

export type BillboardOpts = {
	alwaysOnTop: boolean?,
	widthStuds: number?,
	lineHeightStuds: number?,
	studsOffset: Vector3?,
	name: string?,
}

export type SpotProps = {
	angle: number,
	range: number,
	brightness: number,
	color: Color3?,
	face: Enum.NormalId?,
}

export type PointProps = {
	range: number,
	brightness: number,
	color: Color3?,
}

export type BlockLetters = {
	model: Model,
	parts: { BasePart },
}

--------------------------------------------------------------------------------
-- Light budget tally (SOP §2.6/§10: ≤ 50 local lights, all Shadows=false).
-- MakeSpot/MakePoint auto-register; Register is exposed for any light a
-- builder must create directly (e.g. SurfaceLight) so nothing escapes the
-- count HubService asserts after the build.
--------------------------------------------------------------------------------

local registeredLights: { [Light]: boolean } = {}
local registeredLightCount = 0

local LightBudget = {}

function LightBudget.Register(light: Light)
	if registeredLights[light] == nil then
		registeredLights[light] = true
		registeredLightCount += 1
	end
end

function LightBudget.Count(): number
	return registeredLightCount
end

PartKit.LightBudget = LightBudget

--------------------------------------------------------------------------------
-- Primitive factories
--------------------------------------------------------------------------------

local function applyBaseProps(part: BasePart, props: PartProps?)
	local spec: PartProps = props or {}
	part.Anchored = true
	part.Color = spec.color or COLOR_GREYBOX
	part.Material = spec.material or Enum.Material.SmoothPlastic
	part.Transparency = spec.transparency or 0
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	if spec.decor == true then
		part.CanCollide = false
		part.CanTouch = false
		part.CanQuery = false
		part.CastShadow = false
	end
	if spec.canCollide ~= nil then
		part.CanCollide = spec.canCollide
	end
	if spec.canTouch ~= nil then
		part.CanTouch = spec.canTouch
	end
	if spec.canQuery ~= nil then
		part.CanQuery = spec.canQuery
	end
	if spec.castShadow ~= nil then
		part.CastShadow = spec.castShadow
	end
end

function PartKit.MakePart(parent: Instance, name: string, size: Vector3, cframe: CFrame, props: PartProps?): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = cframe
	applyBaseProps(part, props)
	part.Parent = parent
	return part
end

function PartKit.MakeWedge(parent: Instance, name: string, size: Vector3, cframe: CFrame, props: PartProps?): WedgePart
	local wedge = Instance.new("WedgePart")
	wedge.Name = name
	wedge.Size = size
	wedge.CFrame = cframe
	applyBaseProps(wedge, props)
	wedge.Parent = parent
	return wedge
end

-- Cylinder primitives lie along their X axis; this stands one upright.
function PartKit.MakeUprightCylinder(
	parent: Instance,
	name: string,
	height: number,
	diameter: number,
	position: Vector3,
	props: PartProps?
): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Shape = Enum.PartType.Cylinder
	part.Size = Vector3.new(height, diameter, diameter)
	part.CFrame = CFrame.new(position) * CFrame.Angles(0, 0, math.rad(90))
	applyBaseProps(part, props)
	part.Parent = parent
	return part
end

--------------------------------------------------------------------------------
-- Gui factories (SOP §11.1: LightInfluence 0, Brightness 2, PixelsPerStud 50,
-- warm-white TextScaled GothamBold text on dark boards)
--------------------------------------------------------------------------------

function PartKit.MakeSurfaceGui(part: BasePart, name: string, face: Enum.NormalId?): SurfaceGui
	local gui = Instance.new("SurfaceGui")
	gui.Name = name
	gui.Face = face or Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 50
	gui.LightInfluence = 0
	gui.Brightness = 2
	gui.AlwaysOnTop = false
	gui.Parent = part
	return gui
end

function PartKit.MakeLabel(
	parent: Instance,
	name: string,
	text: string,
	position: UDim2,
	size: UDim2,
	textColor: Color3?
): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = name
	label.Text = text
	label.Position = position
	label.Size = size
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.TextColor3 = textColor or COLOR_TEXT_WARM
	label.Parent = parent
	return label
end

-- The shared SOP §4.2/§6.1 billboard component: line 1 renders 1.5× taller
-- than the rest (header line), every line gets a black UIStroke for night
-- readability. Returns the gui plus the labels in line order so callers can
-- live-update countdown/worker-count text.
function PartKit.MakeBillboard(
	part: BasePart,
	maxDistance: number,
	lines: { string },
	opts: BillboardOpts?
): (BillboardGui, { TextLabel })
	local options: BillboardOpts = opts or {}
	local lineHeight = options.lineHeightStuds or 1.5
	local headerHeight = lineHeight * 1.5
	local width = options.widthStuds or 16
	local totalHeight = if #lines > 1 then headerHeight + lineHeight * (#lines - 1) else headerHeight

	local gui = Instance.new("BillboardGui")
	gui.Name = options.name or "InfoBillboard"
	gui.Size = UDim2.fromScale(width, totalHeight) -- BillboardGui scale units are studs
	gui.MaxDistance = maxDistance
	gui.AlwaysOnTop = options.alwaysOnTop == true
	gui.LightInfluence = 0
	gui.Brightness = 2
	if options.studsOffset ~= nil then
		gui.StudsOffset = options.studsOffset
	end

	local labels: { TextLabel } = {}
	local yAccum = 0
	for index, lineText in lines do
		local heightStuds = if index == 1 then headerHeight else lineHeight
		local label = PartKit.MakeLabel(
			gui,
			`Line{index}`,
			lineText,
			UDim2.fromScale(0, yAccum / totalHeight),
			UDim2.fromScale(1, heightStuds / totalHeight),
			COLOR_TEXT_WARM
		)
		local stroke = Instance.new("UIStroke")
		stroke.Color = COLOR_STROKE
		stroke.Thickness = 2
		stroke.Parent = label
		table.insert(labels, label)
		yAccum += heightStuds
	end

	gui.Parent = part
	return gui, labels
end

--------------------------------------------------------------------------------
-- Block-letter marquee font (SOP §11.1: 3D Neon block letters, 2–4 Parts per
-- letter). Glyphs live on a 3-column × 5-row grid; rects are {x, y, w, h}
-- with the origin at the glyph's bottom-left, diags are center-line
-- {x1, y1, x2, y2} strokes rendered as rotated Parts. Diagonals get a
-- slightly smaller depth so their front faces never sit coplanar with the
-- rect segments they cross (no z-fighting, SOP §11.2).
--------------------------------------------------------------------------------

local GLYPH_COLS = 3
local GLYPH_ROWS = 5

type Glyph = {
	rects: { { number } },
	diags: { { number } }?,
}

local GLYPHS: { [string]: Glyph } = {
	A = { rects = { { 0, 0, 1, 5 }, { 2, 0, 1, 5 }, { 1, 4, 1, 1 }, { 1, 2, 1, 1 } } },
	C = { rects = { { 0, 0, 1, 5 }, { 1, 4, 2, 1 }, { 1, 0, 2, 1 } } },
	F = { rects = { { 0, 0, 1, 5 }, { 1, 4, 2, 1 }, { 1, 2, 2, 1 } } },
	G = { rects = { { 0, 0, 1, 5 }, { 1, 4, 2, 1 }, { 1, 0, 2, 1 }, { 2, 1, 1, 2 } } },
	H = { rects = { { 0, 0, 1, 5 }, { 2, 0, 1, 5 }, { 1, 2, 1, 1 } } },
	I = { rects = { { 0, 4, 3, 1 }, { 1, 1, 1, 3 }, { 0, 0, 3, 1 } } },
	M = { rects = { { 0, 0, 1, 5 }, { 2, 0, 1, 5 } }, diags = { { 0.5, 4.8, 1.5, 2.6 }, { 2.5, 4.8, 1.5, 2.6 } } },
	N = { rects = { { 0, 0, 1, 5 }, { 2, 0, 1, 5 } }, diags = { { 1, 5, 2, 0 } } },
	O = { rects = { { 0, 0, 1, 5 }, { 2, 0, 1, 5 }, { 1, 4, 1, 1 }, { 1, 0, 1, 1 } } },
	P = { rects = { { 0, 0, 1, 5 }, { 1, 4, 2, 1 }, { 2, 2, 1, 2 }, { 1, 2, 1, 1 } } },
	R = { rects = { { 0, 0, 1, 5 }, { 1, 4, 2, 1 }, { 2, 2, 1, 2 } }, diags = { { 1, 2.4, 3, 0 } } },
	S = { rects = { { 0, 4, 3, 1 }, { 0, 0, 3, 1 } }, diags = { { 0.5, 4, 2.5, 1 } } },
	T = { rects = { { 0, 4, 3, 1 }, { 1, 0, 1, 4 } } },
	Y = { rects = { { 0, 3, 1, 2 }, { 2, 3, 1, 2 }, { 1, 0, 1, 3 } } },
}

-- Renders one Neon segment Part centered `offsetX/offsetY` from the letter
-- center, rotated `rotation` radians about the facing axis.
local function makeLetterSegment(
	model: Model,
	parts: { BasePart },
	letterCFrame: CFrame,
	color: Color3,
	offsetX: number,
	offsetY: number,
	sizeX: number,
	sizeY: number,
	depth: number,
	rotation: number
)
	local part = PartKit.MakePart(
		model,
		"LetterSegment",
		Vector3.new(sizeX, sizeY, depth),
		letterCFrame * CFrame.new(offsetX, offsetY, 0) * CFrame.Angles(0, 0, rotation),
		{ color = color, material = Enum.Material.Neon, decor = true }
	)
	table.insert(parts, part)
end

-- 3D Neon block letters. `cframe` is the center of the whole string; letters
-- run along its RightVector and face its -Z (Front). Returns the container
-- Model plus the flat letter-part list (ComingSoonBuilder feeds these to the
-- HubService flicker loop).
function PartKit.MakeBlockLetters(
	parent: Instance,
	text: string,
	cframe: CFrame,
	letterHeight: number,
	color: Color3
): BlockLetters
	local model = Instance.new("Model")
	model.Name = "BlockLetters"
	local parts: { BasePart } = {}

	local cell = letterHeight / GLYPH_ROWS
	local letterWidth = cell * GLYPH_COLS
	local gap = cell
	local spaceAdvance = cell * 2
	local depth = math.max(0.8, letterHeight * 0.18)

	-- Pass 1: total advance, so the string centers on `cframe`.
	local total = 0
	for i = 1, #text do
		local ch = string.upper(string.sub(text, i, i))
		total += if ch == " " then spaceAdvance else letterWidth
		if i < #text then
			total += gap
		end
	end

	-- Pass 2: build glyph segments.
	local cursor = -total / 2
	for i = 1, #text do
		local ch = string.upper(string.sub(text, i, i))
		local advance = if ch == " " then spaceAdvance else letterWidth
		if ch ~= " " then
			local glyph = GLYPHS[ch]
			if glyph == nil then
				warn(`[PartKit] MakeBlockLetters: no glyph for "{ch}" — skipped`)
			else
				local letterCFrame = cframe * CFrame.new(cursor + advance / 2, 0, 0)
				for _, rect in glyph.rects do
					local offsetX = (rect[1] + rect[3] / 2 - GLYPH_COLS / 2) * cell
					local offsetY = (rect[2] + rect[4] / 2 - GLYPH_ROWS / 2) * cell
					makeLetterSegment(
						model,
						parts,
						letterCFrame,
						color,
						offsetX,
						offsetY,
						rect[3] * cell,
						rect[4] * cell,
						depth,
						0
					)
				end
				local diags = glyph.diags
				if diags ~= nil then
					for _, diag in diags do
						local dx = diag[3] - diag[1]
						local dy = diag[4] - diag[2]
						local offsetX = ((diag[1] + diag[3]) / 2 - GLYPH_COLS / 2) * cell
						local offsetY = ((diag[2] + diag[4]) / 2 - GLYPH_ROWS / 2) * cell
						local length = math.sqrt(dx * dx + dy * dy) * cell + cell * 0.4
						makeLetterSegment(
							model,
							parts,
							letterCFrame,
							color,
							offsetX,
							offsetY,
							length,
							cell,
							depth * 0.8,
							math.atan2(dy, dx)
						)
					end
				end
			end
		end
		cursor += advance + gap
	end

	model.Parent = parent
	return { model = model, parts = parts }
end

--------------------------------------------------------------------------------
-- Light factories (SOP §10 hard rule: Shadows = false on every lobby light;
-- the ≤ 4 hero-light shadow exceptions are a deliberate manual act elsewhere,
-- never the default path)
--------------------------------------------------------------------------------

function PartKit.MakeSpot(parent: Instance, props: SpotProps): SpotLight
	local light = Instance.new("SpotLight")
	light.Angle = props.angle
	light.Range = props.range
	light.Brightness = props.brightness
	light.Color = props.color or COLOR_LIGHT_WARM
	light.Face = props.face or Enum.NormalId.Bottom
	light.Shadows = false
	light.Parent = parent
	LightBudget.Register(light)
	return light
end

function PartKit.MakePoint(parent: Instance, props: PointProps): PointLight
	local light = Instance.new("PointLight")
	light.Range = props.range
	light.Brightness = props.brightness
	light.Color = props.color or COLOR_LIGHT_WARM
	light.Shadows = false
	light.Parent = parent
	LightBudget.Register(light)
	return light
end

--------------------------------------------------------------------------------
-- Audit helpers
--------------------------------------------------------------------------------

function PartKit.CountParts(model: Instance): number
	local count = 0
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			count += 1
		end
	end
	return count
end

return PartKit
